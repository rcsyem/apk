// NOT EXECUTED in the build sandbox (no Dart/Flutter). Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/data/app_database.dart';
import 'package:local_ai_assistant/data/chat_repository.dart';
import 'package:local_ai_assistant/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late AppDatabase db;
  late ChatRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
        path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    repo = ChatRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('create, add messages, restore in order', () async {
    final c = await repo.createConversation();
    await repo.addMessage(conversationId: c.id, role: MessageRole.user, content: 'مرحبا');
    await repo.addMessage(conversationId: c.id, role: MessageRole.assistant, content: 'أهلاً');
    expect((await repo.messages(c.id)).map((e) => e.content), ['مرحبا', 'أهلاً']);
  });

  test('deleting a conversation cascades to its messages only', () async {
    final a = await repo.createConversation();
    final b = await repo.createConversation();
    await repo.addMessage(conversationId: a.id, role: MessageRole.user, content: 'a');
    await repo.addMessage(conversationId: b.id, role: MessageRole.user, content: 'b');
    await repo.deleteConversation(a.id);
    expect(await repo.messages(a.id), isEmpty);
    expect((await repo.messages(b.id)).length, 1);
  });

  test('partial assistant text survives as interrupted', () async {
    final c = await repo.createConversation();
    final m = await repo.addMessage(
        conversationId: c.id,
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.interrupted);
    await repo.updateMessage(m.id, content: 'نص جزئي', status: MessageStatus.interrupted);
    final r = (await repo.messages(c.id)).single;
    expect(r.content, 'نص جزئي');
    expect(r.status, MessageStatus.interrupted);
  });

  test('delete all', () async {
    await repo.createConversation();
    await repo.createConversation();
    await repo.deleteAllConversations();
    expect(await repo.listConversations(), isEmpty);
  });

  test('settings upsert', () async {
    await repo.setSetting('ctx', '2048');
    await repo.setSetting('ctx', '4096');
    expect(await repo.getSetting('ctx'), '4096');
  });
}
