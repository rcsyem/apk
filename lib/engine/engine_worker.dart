import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'ffi_bindings.dart';

/// Everything that touches the native engine happens in this one isolate.
/// Protocol (main -> worker): [cmd, id, ...args]
///   cmd: load | count | generate | stop (id = generation id to stop) | unload | shutdown
///   worker -> main: ['ready', SendPort] | ['initError', msg]
///                   ['reply', id, ok, a, b] | ['piece', id, text]
///                   ['done', id, rc, stopped, err, promptTokens, genTokens]
/// Every request id gets exactly one terminal answer ('reply' or 'done'), even when
/// the handler throws: errors are caught and reported, never left to kill the isolate.
/// 'shutdown' is answered only AFTER the native engine has been freed (lai_free joins
/// the native thread and releases context + model); only then does the worker close
/// its port and exit. Text crosses isolates as copied Dart Strings.
class WorkerInit {
  WorkerInit(this.out, this.libraryName);
  final SendPort out;
  final String libraryName;
}

/// Entry point signature for the worker isolate (tests may inject a double).
typedef WorkerEntry = void Function(WorkerInit init);

_Worker? _tryCreateWorker(WorkerInit init) {
  try {
    return _Worker(init.libraryName, init.out);
  } catch (e) {
    // Library missing / wrong ABI / missing symbol: report and let the isolate end.
    init.out.send(['initError', e.toString()]);
    return null;
  }
}

void engineWorkerMain(WorkerInit init) {
  final w = _tryCreateWorker(init);
  if (w == null) return;
  final port = ReceivePort();
  w.closePort = port.close;
  port.listen((Object? m) => w.handle(m as List<Object?>));
  init.out.send(['ready', port.sendPort]);
}

class _Marshal {
  _Marshal(List<String> roles, List<String> contents)
      : n = roles.length,
        roles = calloc<Pointer<Utf8>>(roles.length),
        contents = calloc<Pointer<Utf8>>(roles.length) {
    for (var i = 0; i < n; i++) {
      this.roles[i] = roles[i].toNativeUtf8();
      this.contents[i] = contents[i].toNativeUtf8();
    }
  }
  final int n;
  final Pointer<Pointer<Utf8>> roles;
  final Pointer<Pointer<Utf8>> contents;
  void free() {
    for (var i = 0; i < n; i++) {
      calloc.free(roles[i]);
      calloc.free(contents[i]);
    }
    calloc.free(roles);
    calloc.free(contents);
  }
}

class _Worker {
  _Worker(String libName, this._out) : _b = LaiBindings(DynamicLibrary.open(libName));
  final SendPort _out;
  final LaiBindings _b;
  void Function() closePort = () {};
  Pointer<Void> _engine = nullptr;
  bool _generating = false;
  int _activeGen = 0;
  int _cap = 4096;
  late Pointer<Uint8> _buf = calloc<Uint8>(_cap);
  final Pointer<Int32> _len = calloc<Int32>();
  static const _errLen = 512;

  /// Never throws: every command runs through [_run].
  void handle(List<Object?> m) {
    final cmd = m[0] as String;
    final id = m[1] as int;
    switch (cmd) {
      case 'load':
        _run(cmd, id, () async => _load(id, m[2] as String, m[3] as int, m[4] as int));
      case 'count':
        _run(cmd, id, () async => _count(id, (m[2] as List).cast<String>(), (m[3] as List).cast<String>()));
      case 'generate':
        _run(cmd, id, () => _generate(id, (m[2] as List).cast<String>(), (m[3] as List).cast<String>(),
            m[4] as double, m[5] as int));
      case 'stop':
        // Only the generation the caller means: a late stop must never hit the next one.
        if (_engine != nullptr && _generating && (id == 0 || id == _activeGen)) _b.stop(_engine);
      case 'unload':
        _run(cmd, id, () async {
          await _unload();
          _out.send(['reply', id, true, 0, '']);
        });
      case 'shutdown':
        _run(cmd, id, () async {
          await _unload(); // engine fully freed before anything below
          _releaseBuffers();
          _out.send(['reply', id, true, 0, '']);
          closePort(); // isolate exits once its event queue is empty
        });
      default:
        _out.send(['reply', id, false, Lai.errArgs, 'unknown command']);
    }
  }

  /// Starts [body] synchronously (message order is preserved up to its first await)
  /// and converts any exception into the terminal answer the caller is waiting for.
  void _run(String cmd, int id, Future<void> Function() body) {
    body().catchError((Object e, StackTrace st) {
      final msg = 'worker error in $cmd: $e';
      if (cmd == 'generate') {
        _generating = false;
        _out.send(['done', id, Lai.errInternal, 0, msg, 0, 0]);
      } else if (cmd == 'shutdown') {
        _out.send(['reply', id, false, Lai.errInternal, msg]);
        closePort();
      } else {
        _out.send(['reply', id, false, Lai.errInternal, msg]);
      }
    });
  }

  void _load(int id, String path, int nCtx, int threads) {
    if (_engine != nullptr) {
      _out.send(['reply', id, false, Lai.errBusy, 'an engine is already loaded']);
      return;
    }
    final out = calloc<Pointer<Void>>();
    final err = calloc<Uint8>(_errLen).cast<Utf8>();
    final p = path.toNativeUtf8();
    try {
      final rc = _b.load(p, nCtx, threads, out, err, _errLen);
      if (rc == Lai.ok && out.value != nullptr) {
        _engine = out.value;
        _out.send(['reply', id, true, 0, '']);
      } else {
        _out.send(['reply', id, false, rc == Lai.ok ? Lai.errInternal : rc, err.toDartString()]);
      }
    } finally {
      calloc.free(out);
      calloc.free(err);
      calloc.free(p);
    }
  }

  void _count(int id, List<String> roles, List<String> contents) {
    if (_engine == nullptr) {
      _out.send(['reply', id, false, 0, 'engine not loaded']);
      return;
    }
    final mar = _Marshal(roles, contents);
    try {
      final n = _b.countTokens(_engine, mar.roles, mar.contents, mar.n);
      _out.send(['reply', id, n >= 0, n, n >= 0 ? '' : 'token count failed']);
    } finally {
      mar.free();
    }
  }

  Future<void> _generate(int id, List<String> roles, List<String> contents,
      double temperature, int maxNew) async {
    if (_engine == nullptr) {
      _out.send(['done', id, Lai.errInternal, 0, 'engine not loaded', 0, 0]);
      return;
    }
    if (_generating) {
      _out.send(['done', id, Lai.errBusy, 0, 'generation already running', 0, 0]);
      return;
    }
    final err = calloc<Uint8>(_errLen).cast<Utf8>();
    try {
      final mar = _Marshal(roles, contents);
      int rc;
      try {
        rc = _b.start(_engine, mar.roles, mar.contents, mar.n, temperature, maxNew, err, _errLen);
      } finally {
        mar.free(); // the bridge copies the strings before returning
      }
      if (rc != Lai.ok) {
        _out.send(['done', id, rc, 0, err.toDartString(), 0, 0]);
        return;
      }
      _generating = true;
      _activeGen = id;
      while (true) {
        final st = _b.next(_engine, _buf, _cap, 20, _len);
        if (st == Lai.nextPiece) {
          final text = utf8.decode(_buf.asTypedList(_len.value), allowMalformed: true);
          _out.send(['piece', id, text]); // String is copied to the main isolate
        } else if (st == Lai.nextDone) {
          final stopped = calloc<Int32>();
          final pt = calloc<Int32>();
          final gt = calloc<Int32>();
          try {
            final r = _b.result(_engine, stopped, err, _errLen);
            _b.stats(_engine, pt, gt);
            _out.send(['done', id, r, stopped.value, err.toDartString(), pt.value, gt.value]);
          } finally {
            calloc.free(stopped);
            calloc.free(pt);
            calloc.free(gt);
          }
          break;
        } else if (st == Lai.nextSmallBuffer) {
          final need = _len.value;
          calloc.free(_buf);
          _cap = need > _cap ? need : _cap;
          _buf = calloc<Uint8>(_cap);
        } else if (st == Lai.nextInvalid) {
          _b.stop(_engine);
          _out.send(['done', id, Lai.errInternal, 0, 'lai_next rejected its arguments', 0, 0]);
          break;
        }
        // Let queued 'stop' / 'count' / 'unload' messages run between polls.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _generating = false;
      _activeGen = 0;
      calloc.free(err);
    }
  }

  /// Stops any generation, waits until the polling loop has left the engine, then
  /// frees it (lai_free joins the native thread and releases context + model).
  Future<void> _unload() async {
    final eng = _engine;
    if (eng == nullptr) return;
    _b.stop(eng);
    while (_generating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    try {
      _b.free(eng);
    } finally {
      _engine = nullptr;
    }
  }

  void _releaseBuffers() {
    calloc.free(_buf);
    calloc.free(_len);
  }
}
