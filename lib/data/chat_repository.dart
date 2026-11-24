import 'package:sqflite/sqflite.dart';
import 'app_database.dart';
import 'models.dart';

class ChatRepository {
  ChatRepository(this._app);
  final AppDatabase _app;
  Database get _db => _app.db;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<Conversation> createConversation({String title = 'محادثة جديدة'}) async {
    final t = _now();
    final id = await _db.insert(
        'conversations', {'title': title, 'created_at': t, 'updated_at': t});
    return Conversation.fromMap(
        (await _db.query('conversations', where: 'id = ?', whereArgs: [id])).first);
  }

  Future<List<Conversation>> listConversations() async =>
      (await _db.query('conversations', orderBy: 'updated_at DESC, id DESC'))
          .map(Conversation.fromMap)
          .toList();

  Future<void> renameConversation(int id, String title) => _db.update(
      'conversations', {'title': title},
      where: 'id = ?', whereArgs: [id]);

  Future<void> deleteConversation(int id) =>
      _db.delete('conversations', where: 'id = ?', whereArgs: [id]);

  Future<void> deleteAllConversations() => _db.delete('conversations');

  Future<List<ChatMessage>> messages(int conversationId) async =>
      (await _db.query('messages',
              where: 'conversation_id = ?',
              whereArgs: [conversationId],
              orderBy: 'id ASC'))
          .map(ChatMessage.fromMap)
          .toList();

  Future<ChatMessage> addMessage({
    required int conversationId,
    required MessageRole role,
    required String content,
    MessageStatus status = MessageStatus.complete,
  }) async {
    final t = _now();
    late int id;
    await _db.transaction((txn) async {
      id = await txn.insert('messages', {
        'conversation_id': conversationId,
        'role': role.name,
        'content': content,
        'status': status.name,
        'created_at': t,
      });
      await txn.update('conversations', {'updated_at': t},
          where: 'id = ?', whereArgs: [conversationId]);
    });
    return ChatMessage.fromMap(
        (await _db.query('messages', where: 'id = ?', whereArgs: [id])).first);
  }

  Future<void> deleteMessage(int id) =>
      _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  /// Persists streamed partial text; safe to call repeatedly.
  Future<void> updateMessage(int id,
          {required String content, required MessageStatus status}) =>
      _db.update('messages', {'content': content, 'status': status.name},
          where: 'id = ?', whereArgs: [id]);

  Future<String?> getSetting(String key) async {
    final r = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => _db.insert(
      'settings', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);
}
