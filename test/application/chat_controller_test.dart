// NOT EXECUTED. Run: flutter test. FAKE engine: application logic only.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/data/models.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';
import '../helpers/fakes.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  test('streams a reply, persists both messages, restores after "restart"', () async {
    await env.chat.send('مرحبا');
    final m = env.chat.messages;
    expect(m.map((x) => x.role), [MessageRole.user, MessageRole.assistant]);
    expect(m.last.content, 'مرحبا بك');
    expect(m.last.status, MessageStatus.complete);
    // "restart": a new controller over the same DB sees the history
    final stored = await env.chatRepo.messages(env.chat.current!.id);
    expect(stored.length, 2);
  });

  test('follow-up keeps context: previous turns are passed to the engine', () async {
    await env.chat.send('الأول');
    await env.chat.send('الثاني');
    expect(env.engine.lastTurns.length, 3); // user, assistant, user
    expect(env.engine.lastTurns.first.role, ChatRole.user);
    expect(env.engine.lastTurns.last.content, 'الثاني');
  });

  test('stop mid-generation keeps the partial text as interrupted', () async {
    env.engine.script = List.generate(100, (i) => 'ك$i ');
    env.engine.pieceDelay = const Duration(milliseconds: 5);
    final f = env.chat.send('اكتب');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await env.chat.stop();
    await f;
    final last = env.chat.messages.last;
    expect(last.role, MessageRole.assistant);
    expect(last.status, MessageStatus.interrupted);
    expect(last.content.isNotEmpty, isTrue);
    expect(last.content.length < 100 * 3, isTrue);
  });

  test('engine failure mid-stream keeps earlier messages and the partial reply', () async {
    await env.chat.send('سؤال أول');
    env.engine.throwAfterFirstPiece = true;
    await env.chat.send('سؤال ثان');
    final m = env.chat.messages;
    expect(m.length, 4);
    expect(m[0].content, 'سؤال أول');
    expect(m[1].status, MessageStatus.complete);
    expect(m[3].status, MessageStatus.failed);
    expect(m[3].content, 'مرحبا');
    expect(env.chat.notice, isNotNull);
  });

  test('load failure: user message is kept, no empty assistant bubble, Arabic notice', () async {
    env.engine.failLoadWith = EngineException(EngineErrorCode.outOfMemory);
    await env.chat.send('مرحبا');
    expect(env.chat.messages.map((x) => x.role), [MessageRole.user]);
    expect(env.chat.notice, contains('الذاكرة'));
    final stored = await env.chatRepo.messages(env.chat.current!.id);
    expect(stored.length, 1);
  });

  test('no model selected: message saved, clear notice', () async {
    await env.settings.setActiveModelId(null);
    await env.chat.send('مرحبا');
    expect(env.chat.messages.length, 1);
    expect(env.chat.notice, isNotNull);
  });

  test('background stops generation, persists, then unloads the model', () async {
    env.engine.script = List.generate(100, (i) => 'ك$i ');
    env.engine.pieceDelay = const Duration(milliseconds: 5);
    final f = env.chat.send('اكتب');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await env.chat.onBackground();
    await f;
    expect(env.engine.log.contains('stop'), isTrue);
    expect(env.engine.log.contains('unload'), isTrue);
    expect(env.models.loadedId, isNull);
    final stored = await env.chatRepo.messages(env.chat.current!.id);
    expect(stored.last.status, MessageStatus.interrupted);
    expect(stored.last.content.isNotEmpty, isTrue);
  });

  test('reopening does not auto-load the model', () async {
    expect(env.engine.log.where((l) => l.startsWith('load:')), isEmpty);
  });

  test('a prompt that cannot fit gives a clear error and keeps the message', () async {
    await env.settings.setContextLength(512);
    await env.chat.send('ا' * 5000);
    expect(env.chat.messages.length, 1);
    expect(env.chat.notice, contains('السياق'));
  });
}
