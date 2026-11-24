// NOT EXECUTED (no Dart/Flutter SDK in the build sandbox). Run: flutter test
// Lifecycle tests of FfiInferenceEngine with DOUBLE worker isolates (top-level
// functions, as Isolate.spawn requires) plus the real worker with a missing
// library. None of these touches llama.cpp or a real liblai_bridge.so.
import 'dart:async';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/engine/engine_worker.dart';
import 'package:local_ai_assistant/engine/ffi_inference_engine.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';

const _t = Duration(seconds: 10);
const _req = ModelLoadRequest(path: '/x.gguf');
const _turns = [ChatTurn(ChatRole.user, 'hi')];

void _entryInitError(WorkerInit i) => i.out.send(['initError', 'boom']);

void _entryExitsSilently(WorkerInit i) {} // returns without 'ready': isolate just ends

void _entryDiesOnLoad(WorkerInit i) {
  final port = ReceivePort();
  port.listen((Object? m) {
    if ((m as List)[0] == 'load') Isolate.exit(); // dies with a request outstanding
  });
  i.out.send(['ready', port.sendPort]);
}

/// Answers everything; 'generate' streams pieces until it gets 'stop' for that id.
/// With i.libraryName == 'die-mid-generation' it exits after the first piece instead.
void _entryScripted(WorkerInit i) {
  final port = ReceivePort();
  var stopped = false;
  port.listen((Object? raw) async {
    final m = raw as List;
    final cmd = m[0] as String, id = m[1] as int;
    switch (cmd) {
      case 'load':
        i.out.send(['reply', id, true, 0, '']);
      case 'generate':
        stopped = false;
        var n = 0;
        while (!stopped) {
          i.out.send(['piece', id, 'x']);
          n++;
          if (i.libraryName == 'die-mid-generation') Isolate.exit();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        i.out.send(['done', id, 0, 1, '', 1, n]);
      case 'stop':
        stopped = true;
      case 'unload':
        i.out.send(['reply', id, true, 0, '']);
      case 'shutdown':
        i.out.send(['reply', id, true, 0, '']);
        port.close();
    }
  });
  i.out.send(['ready', port.sendPort]);
}

void main() {
  test('missing native library: load fails fast with EngineException, state back to idle, retry also fails', () async {
    final e = FfiInferenceEngine(libraryName: '/nonexistent/liblai_bridge.so');
    await expectLater(e.loadModel(_req).timeout(_t), throwsA(isA<EngineException>()));
    expect(e.state, EngineState.idle);
    await expectLater(e.loadModel(_req).timeout(_t), throwsA(isA<EngineException>()));
    await e.dispose().timeout(_t);
  });

  test('worker reports initError: load throws with the reason', () async {
    final e = FfiInferenceEngine(workerEntry: _entryInitError);
    await expectLater(
        e.loadModel(_req).timeout(_t),
        throwsA(isA<EngineException>().having((x) => x.detail, 'detail', contains('boom'))));
    expect(e.state, EngineState.idle);
    await e.dispose().timeout(_t);
  });

  test('worker exits before ready: load does not hang', () async {
    final e = FfiInferenceEngine(workerEntry: _entryExitsSilently);
    await expectLater(e.loadModel(_req).timeout(_t), throwsA(isA<EngineException>()));
    expect(e.state, EngineState.idle);
  });

  test('worker dies while a load request is outstanding: request fails, no hang', () async {
    final e = FfiInferenceEngine(workerEntry: _entryDiesOnLoad);
    await expectLater(e.loadModel(_req).timeout(_t), throwsA(isA<EngineException>()));
    expect(e.state, EngineState.idle);
  });

  test('worker dies mid-generation: stream errors and closes, state error, unload completes', () async {
    final e = FfiInferenceEngine(libraryName: 'die-mid-generation', workerEntry: _entryScripted);
    await e.loadModel(_req).timeout(_t);
    final events = <Object>[];
    final done = Completer<void>();
    e.generate(_turns, const GenerationParams()).listen(events.add,
        onError: events.add, onDone: done.complete);
    await done.future.timeout(_t);
    expect(events.whereType<EngineException>(), isNotEmpty);
    expect(e.state, EngineState.error);
    await e.stop(); // must not throw
    await e.unload().timeout(_t);
    expect(e.state, EngineState.idle);
  });

  test('cancelling the stream subscription stops the generation and frees the engine for reuse', () async {
    final e = FfiInferenceEngine(workerEntry: _entryScripted);
    await e.loadModel(_req).timeout(_t);
    final first = Completer<void>();
    final sub = e.generate(_turns, const GenerationParams()).listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(_t);
    await sub.cancel();
    await e.stateChanges.firstWhere((s) => s == EngineState.ready).timeout(_t);
    await e.dispose().timeout(_t);
  });

  test('dispose during generation: stop -> done -> unload -> shutdown, no hang, stream completes', () async {
    final e = FfiInferenceEngine(workerEntry: _entryScripted);
    await e.loadModel(_req).timeout(_t);
    final closed = Completer<void>();
    e.generate(_turns, const GenerationParams()).listen((_) {}, onDone: closed.complete);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await e.dispose().timeout(_t);
    await closed.future.timeout(_t);
  });

  test('unload while a load is still in flight waits for it', () async {
    final e = FfiInferenceEngine(workerEntry: _entryScripted);
    final loading = e.loadModel(_req);
    final unloading = e.unload();
    await loading.timeout(_t);
    await unloading.timeout(_t);
    expect(e.state, EngineState.idle);
    await e.dispose().timeout(_t);
  });
}
