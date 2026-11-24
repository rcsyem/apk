import 'dart:async';
import 'dart:isolate';
import 'engine_worker.dart';
import 'ffi_bindings.dart';
import 'inference_engine.dart';

/// Real [InferenceEngine] backed by liblai_bridge.so through dart:ffi.
/// UNBUILT / UNTESTED: needs the Android build and a real llama.cpp.
class FfiInferenceEngine implements InferenceEngine {
  /// [workerEntry] exists for tests only (a double that crashes, never answers...).
  FfiInferenceEngine({this.libraryName = 'liblai_bridge.so', WorkerEntry? workerEntry})
      : _entry = workerEntry ?? engineWorkerMain;
  final String libraryName;
  final WorkerEntry _entry;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  int _nextId = 1;
  final Map<int, Completer<List<Object?>>> _pending = {};
  final Map<int, StreamController<String>> _gens = {};
  Completer<void>? _genFinished;
  int _activeGen = 0;
  ReceivePort? _exitPort;
  ReceivePort? _errorPort;
  Completer<void> _exited = Completer<void>()..complete();
  bool _shuttingDown = false;
  Future<void>? _loading;
  Stopwatch? _genWatch;
  int _firstPieceMs = -1;

  EngineState _state = EngineState.idle;
  final StreamController<EngineState> _stateCtl = StreamController<EngineState>.broadcast();
  int _contextLength = 0;
  GenerationStats? _lastStats;

  @override
  EngineState get state => _state;
  @override
  Stream<EngineState> get stateChanges => _stateCtl.stream;
  @override
  int get contextLength => _contextLength;
  @override
  GenerationStats? get lastStats => _lastStats;

  void _setState(EngineState s) {
    if (_state == s) return;
    _state = s;
    _stateCtl.add(s);
  }

  Future<void> _ensureWorker() async {
    if (_toWorker != null) return;
    final rp = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    final ready = Completer<void>();
    _exited = Completer<void>();
    _shuttingDown = false;
    rp.listen((Object? raw) {
      final msg = raw as List<Object?>;
      final kind = msg[0] as String;
      if (kind == 'ready') {
        _toWorker = msg[1] as SendPort;
        if (!ready.isCompleted) ready.complete();
      } else if (kind == 'initError') {
        if (!ready.isCompleted) {
          ready.completeError(EngineException(
              EngineErrorCode.unknown, 'native library unavailable: ${msg[1]}'));
        }
      } else if (kind == 'reply') {
        _pending.remove(msg[1] as int)?.complete(msg);
      } else if (kind == 'piece') {
        _firstPieceMs = _firstPieceMs >= 0 ? _firstPieceMs : (_genWatch?.elapsedMilliseconds ?? 0);
        _gens[msg[1] as int]?.add(msg[2] as String);
      } else if (kind == 'done') {
        _onDone(msg);
      }
    });
    // The worker may die at any time (uncaught error, killed, exited before 'ready').
    // Either signal fails every outstanding request instead of leaving it hanging.
    exitPort.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(EngineException(EngineErrorCode.unknown, 'worker exited before ready'));
      }
      _onWorkerGone('worker isolate exited');
    });
    errorPort.listen((Object? e) {
      if (!ready.isCompleted) {
        ready.completeError(EngineException(EngineErrorCode.unknown, 'worker failed: $e'));
      }
      _onWorkerGone('worker isolate error: $e');
    });
    _fromWorker = rp;
    _exitPort = exitPort;
    _errorPort = errorPort;
    try {
      _isolate = await Isolate.spawn(_entry, WorkerInit(rp.sendPort, libraryName),
          onExit: exitPort.sendPort, onError: errorPort.sendPort);
      await ready.future;
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
      _teardownWorkerState();
      rethrow;
    }
  }

  void _closePorts() {
    _fromWorker?.close();
    _exitPort?.close();
    _errorPort?.close();
    _fromWorker = _exitPort = _errorPort = null;
  }

  void _teardownWorkerState() {
    _toWorker = null;
    _isolate = null;
    _closePorts();
  }

  /// Idempotent. Called when the worker isolate exited or failed. Fails all pending
  /// requests and open generation streams so nothing waits forever. If the worker
  /// died unexpectedly, the native engine it owned cannot be freed from here (its
  /// pointer lives only in that isolate): that memory stays allocated until the
  /// app process ends. The state becomes [EngineState.error]; a new loadModel
  /// starts a fresh worker.
  void _onWorkerGone(String reason) {
    if (_fromWorker == null && _toWorker == null && _pending.isEmpty && _gens.isEmpty) {
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    final expected = _shuttingDown;
    final err = EngineException(EngineErrorCode.unknown, reason);
    _teardownWorkerState();
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(err);
    }
    final gens = _gens.values.toList();
    _gens.clear();
    for (final ctl in gens) {
      if (!ctl.isClosed) {
        ctl.addError(err);
        ctl.close();
      }
    }
    _activeGen = 0;
    _genFinished?.complete();
    _genFinished = null;
    if (!_exited.isCompleted) _exited.complete();
    // While loading, loadModel's own catch decides the state.
    if (!expected && _state != EngineState.loading && _state != EngineState.idle) {
      _setState(EngineState.error);
    }
  }

  void _onDone(List<Object?> msg) {
    final id = msg[1] as int;
    final rc = msg[2] as int;
    final err = msg[4] as String;
    final ctl = _gens.remove(id);
    final total = _genWatch?.elapsedMilliseconds ?? 0;
    _lastStats = GenerationStats(
      promptTokens: msg[5] as int,
      generatedTokens: msg[6] as int,
      firstTokenMs: _firstPieceMs,
      totalMs: total,
    );
    if (rc != Lai.ok && ctl != null && !ctl.isClosed) ctl.addError(_mapError(rc, err));
    ctl?.close();
    _genFinished?.complete();
    _genFinished = null;
    if (_activeGen == id) _activeGen = 0;
    if (_state == EngineState.generating) _setState(EngineState.ready);
  }

  Future<List<Object?>> _request(String cmd, List<Object?> args) {
    final to = _toWorker;
    if (to == null) {
      return Future<List<Object?>>.error(EngineException(EngineErrorCode.notReady, 'worker not running'));
    }
    final id = _nextId++;
    final c = Completer<List<Object?>>();
    _pending[id] = c;
    to.send([cmd, id, ...args]);
    return c.future;
  }

  static EngineException _mapError(int rc, String msg) {
    final code = switch (rc) {
      Lai.errFile => EngineErrorCode.modelNotFound,
      Lai.errModel => EngineErrorCode.modelCorrupt,
      Lai.errContext => EngineErrorCode.outOfMemory,
      Lai.errTemplate => EngineErrorCode.modelIncompatible,
      Lai.errPromptTooLong => EngineErrorCode.contextExceeded,
      Lai.errBusy => EngineErrorCode.busy,
      Lai.errTokenize || Lai.errDecode => EngineErrorCode.generationFailed,
      _ => EngineErrorCode.unknown,
    };
    return EngineException(code, msg);
  }

  @override
  Future<void> loadModel(ModelLoadRequest r) {
    if (_state != EngineState.idle && _state != EngineState.error) {
      return Future<void>.error(EngineException(EngineErrorCode.busy, 'engine is ${_state.name}'));
    }
    _setState(EngineState.loading);
    final f = _doLoad(r);
    _loading = f;
    return f.whenComplete(() {
      if (identical(_loading, f)) _loading = null;
    });
  }

  Future<void> _doLoad(ModelLoadRequest r) async {
    try {
      await _ensureWorker();
      final rep = await _request('load', [r.path, r.contextLength, r.threads]);
      if (rep[2] != true) throw _mapError(rep[3] as int, rep[4] as String);
      _contextLength = r.contextLength;
      _setState(EngineState.ready);
    } catch (_) {
      _setState(EngineState.idle);
      rethrow;
    }
  }

  @override
  Future<int> countPromptTokens(List<ChatTurn> turns) async {
    if (_state != EngineState.ready && _state != EngineState.generating) {
      throw EngineException(EngineErrorCode.notReady);
    }
    final rep = await _request('count', [
      [for (final t in turns) t.role.name],
      [for (final t in turns) t.content],
    ]);
    if (rep[2] != true) throw EngineException(EngineErrorCode.generationFailed, rep[4] as String);
    return rep[3] as int;
  }

  @override
  Stream<String> generate(List<ChatTurn> turns, GenerationParams params) {
    final to = _toWorker;
    if (_state != EngineState.ready || to == null) {
      return Stream<String>.error(EngineException(EngineErrorCode.notReady));
    }
    final id = _nextId++;
    final ctl = StreamController<String>(onCancel: () {
      // The consumer walked away: do not leave the native generation running.
      if (_gens.containsKey(id)) _toWorker?.send(['stop', id]);
    });
    _gens[id] = ctl;
    _activeGen = id;
    _genFinished = Completer<void>();
    _genWatch = Stopwatch()..start();
    _firstPieceMs = -1;
    _setState(EngineState.generating);
    to.send([
      'generate',
      id,
      [for (final t in turns) t.role.name],
      [for (final t in turns) t.content],
      params.temperature,
      params.maxNewTokens,
    ]);
    return ctl.stream;
  }

  @override
  Future<void> stop() async {
    if (_state == EngineState.generating && _activeGen != 0) _toWorker?.send(['stop', _activeGen]);
  }

  /// Completes normally even if the worker died meanwhile (state then is [EngineState.error]).
  @override
  Future<void> unload() async {
    final inFlight = _loading;
    if (inFlight != null) {
      try {
        await inFlight; // never interleave unload with a load that is still running
      } catch (_) {}
    }
    if (_toWorker == null) {
      _setState(EngineState.idle);
      return;
    }
    if (_state == EngineState.generating) {
      await stop();
      await _genFinished?.future; // completed by 'done' or by worker death
    }
    if (_toWorker == null) {
      _setState(EngineState.idle); // worker died while we waited
      return;
    }
    _setState(EngineState.unloading);
    try {
      await _request('unload', const []);
    } on EngineException {
      // Worker died during unload; _onWorkerGone already set the state.
    } finally {
      if (_state == EngineState.unloading) _setState(EngineState.idle);
    }
  }

  /// Frees the engine, then shuts the worker down. The worker answers 'shutdown'
  /// only after lai_free returned, so the isolate is never closed while native
  /// memory is still held. A dead worker is simply cleaned up.
  Future<void> dispose() async {
    try {
      await unload();
    } catch (_) {}
    if (_toWorker != null) {
      _shuttingDown = true;
      try {
        await _request('shutdown', const []);
        await _exited.future.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Reply received (engine already freed) but the isolate did not exit in time,
        // or the worker was already gone: nothing native is left to protect.
      }
      _isolate?.kill(priority: Isolate.immediate);
      _teardownWorkerState();
    }
    await _stateCtl.close();
  }
}
