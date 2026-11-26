import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import '../engine/inference_engine.dart';
import '../models/model_manager.dart';
import '../presentation/strings_ar.dart';
import 'app_settings.dart';
import 'context_builder.dart';
import 'error_messages.dart';

/// Five distinct UI states as required by spec v0.4.7:
///  - noModel: no model selected or installed
///  - loading: model is currently being loaded into memory
///  - ready: active model loaded/ready to receive prompts
///  - generating: engine is streaming a response
///  - error: latest operation encountered an error
enum ChatUiState {
  noModel,
  loading,
  ready,
  generating,
  error,
}

/// Conversations + streaming generation. Invariants:
///  - the user's message is saved only when processing can proceed;
///  - partial assistant text is persisted while streaming;
///  - a failure never corrupts or deletes earlier messages;
///  - deletion is blocked during generation.
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
  bool _sending = false;
  bool _lastFailed = false;
  bool _disposed = false;
  Future<void>? _generationDone;

  bool get generating => _generating;

  @visibleForTesting
  void setGeneratingForTesting(bool value) {
    _generating = value;
    notifyListeners();
  }
  bool get canSend => state == ChatUiState.ready && !_sending;

  ChatUiState get state {
    if (_generating) return ChatUiState.generating;
    if (_models.loading) return ChatUiState.loading;
    if (_models.active == null) return ChatUiState.noModel;
    if (notice != null && _lastFailed) return ChatUiState.error;
    return ChatUiState.ready;
  }

  static const Duration _persistEvery = Duration(milliseconds: 400);

  Future<void> init() async {
    _models.addListener(_onModelsChanged);
    conversations = await _repo.listConversations();
    if (conversations.isNotEmpty) await open(conversations.first);
    notifyListeners();
  }

  void _onModelsChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _models.removeListener(_onModelsChanged);
    super.dispose();
  }

  Future<void> open(Conversation c) async {
    if (_generating) return; // do not switch conversations mid-generation
    current = c;
    messages = await _repo.messages(c.id);
    notice = null;
    _lastFailed = false;
    notifyListeners();
  }

  Future<void> newConversation() async {
    if (_generating) return;
    final c = await _repo.createConversation(title: S.defaultConversationTitle);
    conversations = await _repo.listConversations();
    await open(c);
  }

  Future<bool> delete(Conversation c) async {
    if (_generating) {
      notice = S.cannotDeleteWhileGenerating;
      notifyListeners();
      return false;
    }
    await _repo.deleteConversation(c.id);
    conversations = await _repo.listConversations();
    if (current?.id == c.id) {
      current = null;
      messages = [];
      if (conversations.isNotEmpty) await open(conversations.first);
    }
    notifyListeners();
    return true;
  }

  Future<bool> deleteAll() async {
    if (_generating) {
      notice = S.cannotDeleteWhileGenerating;
      notifyListeners();
      return false;
    }
    await _repo.deleteAllConversations();
    conversations = [];
    messages = [];
    current = null;
    notifyListeners();
    return true;
  }

  void _replace(int id, String content) {
    final i = messages.indexWhere((m) => m.id == id);
    if (i >= 0) messages[i] = messages[i].copyWith(content: content);
  }

  static String generateTitle(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return S.defaultConversationTitle;
    if (clean.length <= 40) return clean;
    final sub = clean.substring(0, 40);
    final lastSpace = sub.lastIndexOf(' ');
    if (lastSpace > 20) {
      return sub.substring(0, lastSpace).trim();
    }
    return sub.trim();
  }

  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _generating || _sending) return;

    if (_models.active == null) {
      notice = S.noModelBannerDesc;
      _lastFailed = true;
      notifyListeners();
      return;
    }

    _sending = true;
    _lastFailed = false;
    notice = null;
    notifyListeners();

    // Invariant: verify the model is loaded BEFORE inserting a new message.
    // If loading fails, do not record a message as successfully sent.
    try {
      await _models.ensureLoaded();
    } on ModelLoadException catch (e) {
      _lastFailed = true;
      notice = e.messageAr;
      _sending = false;
      notifyListeners();
      return;
    } on EngineException catch (e) {
      _lastFailed = true;
      notice = ErrorMessages.engine(e);
      _sending = false;
      notifyListeners();
      return;
    } catch (e, st) {
      debugPrint('Unexpected error loading model: $e\n$st');
      _lastFailed = true;
      notice = 'تعذّر تحميل النموذج إلى الذاكرة. تأكد من توفر مساحة كافية.';
      _sending = false;
      notifyListeners();
      return;
    }

    if (current == null) await newConversation();
    final c = current!;
    final first = messages.isEmpty;

    await _repo.addMessage(conversationId: c.id, role: MessageRole.user, content: t);
    if (first || c.title == S.defaultConversationTitle || c.title.trim().isEmpty) {
      final safeTitle = generateTitle(t);
      await _repo.renameConversation(c.id, safeTitle);
    }

    final placeholder = await _repo.addMessage(
        conversationId: c.id,
        role: MessageRole.assistant,
        content: '',
        status: MessageStatus.interrupted);

    conversations = await _repo.listConversations();
    current = conversations.firstWhere((x) => x.id == c.id, orElse: () => c);
    messages = await _repo.messages(c.id);

    _generating = true;
    _stopRequested = false;
    final finished = Completer<void>();
    _generationDone = finished.future;
    notifyListeners();

    var content = '';
    var status = MessageStatus.complete;
    String? failure;

    try {
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
      _lastFailed = true;
    } on EngineException catch (e) {
      status = MessageStatus.failed;
      failure = ErrorMessages.engine(e);
      _lastFailed = true;
    } catch (e, st) {
      debugPrint('Unexpected error during generation: $e\n$st');
      status = MessageStatus.failed;
      failure = 'حدث خطأ غير متوقع. رسائلك السابقة محفوظة.';
      _lastFailed = true;
    } finally {
      try {
        if (content.isEmpty) {
          await _repo.deleteMessage(placeholder.id); // nothing worth keeping
          if (status == MessageStatus.complete) failure = 'لم يولّد النموذج أي رد. جرّب صياغة أخرى.';
        } else {
          await _repo.updateMessage(placeholder.id, content: content, status: status);
        }
        messages = await _repo.messages(c.id);
      } catch (e, st) {
        debugPrint('Error finalizing message in DB: $e\n$st');
        failure ??= 'تعذّر حفظ آخر رد.';
      }
      notice = failure;
      _generating = false;
      _sending = false;
      if (!finished.isCompleted) finished.complete();
      notifyListeners();
    }
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
