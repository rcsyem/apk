enum MessageRole { user, assistant }

/// complete: finished; interrupted: user stop / app backgrounded;
/// failed: engine error. Partial text is never discarded.
enum MessageStatus { complete, interrupted, failed }

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });
  final int id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Conversation.fromMap(Map<String, Object?> m) => Conversation(
        id: m['id'] as int,
        title: m['title'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
  });
  final int id;
  final int conversationId;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final DateTime createdAt;

  ChatMessage copyWith({String? content, MessageStatus? status}) => ChatMessage(
        id: id,
        conversationId: conversationId,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        createdAt: createdAt,
      );

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as int,
        conversationId: m['conversation_id'] as int,
        role: MessageRole.values.byName(m['role'] as String),
        content: m['content'] as String,
        status: MessageStatus.values.byName(m['status'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}
