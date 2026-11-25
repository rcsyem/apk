import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/application/error_messages.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';
import 'package:local_ai_assistant/models/model_manager.dart';
import '../helpers/fakes.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create(models: 2));
  tearDown(() => env.dispose());

  test('loads the active model once and transitions to ready state', () async {
    expect(env.models.state, ModelLifecycleState.downloaded);
    await env.models.ensureLoaded();
    expect(env.models.state, ModelLifecycleState.ready);
    await env.models.ensureLoaded();
    expect(env.engine.log.where((l) => l.startsWith('load:')).length, 1);
    expect(env.models.loadedId, 'm1');
  });

  test('switching: stop -> unload completes BEFORE the next load and updates state', () async {
    await env.models.ensureLoaded();
    expect(env.models.state, ModelLifecycleState.ready);

    await env.models.switchModel('m2', loadImmediately: true);
    final log = env.engine.log;
    expect(log.indexOf('unload'), lessThan(log.indexOf('load:m2.gguf')));
    expect(log.where((l) => l.startsWith('load:')).toList(), ['load:m1.gguf', 'load:m2.gguf']);
    expect(env.models.loadedId, 'm2');
    expect(env.models.state, ModelLifecycleState.ready);
  });

  test('concurrent ensureLoaded calls never load twice (serialized via lock)', () async {
    env.engine.loadDelay = const Duration(milliseconds: 30);
    await Future.wait([env.models.ensureLoaded(), env.models.ensureLoaded(), env.models.ensureLoaded()]);
    expect(env.engine.log.where((l) => l.startsWith('load:')).length, 1);
  });

  test('changing context length reloads safely', () async {
    await env.models.ensureLoaded();
    await env.settings.setContextLength(1024);
    await env.models.ensureLoaded();
    expect(env.engine.log.where((l) => l.startsWith('load:')).length, 2);
    expect(env.engine.log.contains('unload'), isTrue);
  });

  test('memory policy can refuse the load (no native load attempted, state is error)', () async {
    env.native.snapshot = env.native.snapshot.lowAvailable(100 << 20);
    await expectLater(env.models.ensureLoaded(), throwsA(isA<ModelLoadException>()));
    expect(env.engine.log.where((l) => l.startsWith('load:')), isEmpty);
    expect(env.models.state, ModelLifecycleState.error);
  });

  test('no active model -> clear error and noModel state', () async {
    await env.settings.setActiveModelId(null);
    await expectLater(env.models.ensureLoaded(), throwsA(isA<ModelLoadException>()));
    expect(env.models.state, ModelLifecycleState.noModel);
  });

  test('engine failure propagates and leaves state as error without leaving loaded id', () async {
    env.engine.failLoadWith = EngineException(EngineErrorCode.outOfMemory);
    await expectLater(env.models.ensureLoaded(), throwsA(isA<EngineException>()));
    expect(env.models.loadedId, isNull);
    expect(env.models.state, ModelLifecycleState.error);
  });

  test('delete of the loaded model unloads it first and removes file + row', () async {
    await env.models.ensureLoaded();
    await env.models.delete('m1');
    expect(env.engine.log.contains('unload'), isTrue);
    expect(env.models.installed.map((m) => m.id), ['m2']);
    expect(env.settings.activeModelId, isNull);
  });
}
