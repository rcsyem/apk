import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import '../engine/inference_engine.dart';
import '../models/model_manager.dart';
import 'app_settings.dart';
import 'context_builder.dart';
import 'error_messages.dart';

/// Conversations + streaming generation. Invariants:
///  - the user's message is saved BEFORE anything can fail;
///  - partial assistant text is persisted (throttled) while streaming;
///  - a failure never touches earlier messages.
class ChatController extends ChangeNotifier {
  ChatController(this._repo, this._engine, this._models, this._settings);
  final ChatRepository _repo;
  final InferenceEngine _engine;
  final ModelManager _models;
  final AppSettings _settings;

  List<Conversation> conversations = [];
  List<ChatMessage> messages = [];
  Conversation? current;
  String? notice;

  bool _generating = false;
  bool _stopRequested = false;
  Future<void>? _generationDone;
  bool get generating => _generating;

  static const Duration _persistEvery = Duration(milliseconds: 400);

  Future<void> init() async {
    conversations = await _repo.listConversations();
    if (conversations.isNotEmpty) await open(conversations.first);
    notifyListeners();
  }

  Future<void> open(Conversation c) async {
    if (_generating) return; // do not switch conversations mid-generation
    current = c;
    messages = await _repo.messages(c.id);
    notice = null;
    notifyListeners();
  }

  Future<void> newConversation() async {
    if (_generating) return;
    final c = await _repo.createConversation();
    conversations = await _repo.listConversations();
    await open(c);
  }

  Future<void> delete(Conversation c) async {
    if (_generating && current?.id == c.id) return;
    await _repo.deleteConversation(c.id);
    conversations = await _repo.listConversations();
    if (current?.id == c.id) {
      current = null;
      messages = [];
      if (conversations.isNotEmpty) await open(conversations.first);
    }
    notifyListeners();
  }

  Future<void> deleteAll() async {
    if (_generating) await stop();
    await _generationDone;
    await _repo.deleteAllConversations();
    conversations = [];
    messages = [];
    current = null;
    notifyListeners();
  }

  void _replace(int id, String content) {
    final i = messages.indexWhere((m) => m.id == id);
    if (i >= 0) messages[i] = messages[i].copyWith(content: content);
  }

  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _generating) return;
    if (current == null) await newConversation();
    final c = current!;
    final first = messages.isEmpty;

    await _repo.addMessage(conversationId: c.id, role: MessageRole.user, content: t);
    if (first) {
      await _repo.renameConversation(c.id, t.length > 40 ? t.substring(0, 40) : t);
    }
    final placeholder = await _repo.addMessage(
        conversationId: c.id,
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.interrupted);
    conversations = await _repo.listConversations();
    current = conversations.firstWhere((x) => x.id == c.id);
    messages = await _repo.messages(c.id);
    notice = null;
    _generating = true;
    _stopRequested = false;
    final finished = Completer<void>();
    _generationDone = finished.future;
    notifyListeners();

    var content = '';
    var status = MessageStatus.complete;
    String? failure;
    try {
      await _models.ensureLoaded();
      final history = messages
          .where((m) => m.id != placeholder.id && m.content.isNotEmpty)
          .map((m) => ChatTurn(m.role == MessageRole.user ? ChatRole.user : ChatRole.assistant, m.content))
          .toList();
      final nCtx = _settings.contextLength;
      final maxNew = math.min(512, nCtx ~/ 2);
      final turns = await ContextBuilder.fit(history,
          budgetTokens: nCtx - maxNew - 16, count: _engine.countPromptTokens);
      final params = GenerationParams(temperature: _settings.temperature, maxNewTokens: maxNew);

      var lastWrite = DateTime.now();
      await for (final piece in _engine.generate(turns, params)) {
        content += piece;
        _replace(placeholder.id, content);
        final now = DateTime.now();
        if (now.difference(lastWrite) >= _persistEvery) {
          lastWrite = now;
          await _repo.updateMessage(placeholder.id, content: content, status: MessageStatus.interrupted);
        }
        notifyListeners();
      }
      status = _stopRequested ? MessageStatus.interrupted : MessageStatus.complete;
    } on ContextTooSmallException {
      status = MessageStatus.failed;
      failure = ErrorMessages.engine(EngineException(EngineErrorCode.contextExceeded));
    } on ModelLoadException catch (e) {
      status = MessageStatus.failed;
      failure = e.messageAr;
    } on EngineException catch (e) {
      status = MessageStatus.failed;
      failure = ErrorMessages.engine(e);
    } catch (_) {
      status = MessageStatus.failed;
      failure = 'حدث خطأ غير متوقع. رسائلك السابقة محفوظة.';
    }

    try {
      if (content.isEmpty) {
        await _repo.deleteMessage(placeholder.id); // nothing worth keeping
        if (status == MessageStatus.complete) failure = 'لم يولّد النموذج أي رد. جرّب صياغة أخرى.';
      } else {
        await _repo.updateMessage(placeholder.id, content: content, status: status);
      }
      messages = await _repo.messages(c.id);
    } catch (_) {
      failure ??= 'تعذّر حفظ آخر رد.';
    }
    notice = failure;
    _generating = false;
    finished.complete();
    notifyListeners();
  }

  Future<void> stop() async {
    _stopRequested = true;
    await _engine.stop();
  }

  /// Android moved us to the background: stop safely, persist, then release the model.
  Future<void> onBackground() async {
    if (_generating) {
      await stop();
      await _generationDone;
    }
    await _models.unload();
  }
}
