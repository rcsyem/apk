import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../application/chat_controller.dart';
import '../../data/models.dart';
import '../../models/model_manager.dart';
import '../settings/settings_screen.dart';
import '../strings_ar.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _handleSend(ChatController c) async {
    final text = _input.text.trim();
    if (text.isEmpty || _isSubmitting || c.generating) return;
    setState(() => _isSubmitting = true);
    _input.clear();
    try {
      await c.send(text);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    final models = context.watch<ModelManager>();
    final hasModel = models.active != null;
    final modelName = models.active?.name ?? S.noModel;
    final isReady = hasModel && !models.loading && !c.generating;
    final canSend = isReady && !_isSubmitting;

    _scrollToEnd();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.current?.title ?? S.appName, overflow: TextOverflow.ellipsis),
          Text(
            '${S.activeModel}: $modelName',
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ]),
        actions: [
          IconButton(
            tooltip: S.newChat,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: c.generating ? null : c.newConversation,
          ),
          IconButton(
            tooltip: S.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      drawer: _HistoryDrawer(controller: c),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: (!hasModel && c.messages.isEmpty)
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.smart_toy_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            S.noModelBannerTitle,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            S.noModelBannerDesc,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text(S.goToImportModel),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SettingsScreen()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : (c.messages.isEmpty
                    ? const Center(child: Text(S.emptyChat))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: c.messages.length,
                        itemBuilder: (_, i) => _Bubble(m: c.messages[i]),
                      )),
          ),
          if (!hasModel && c.messages.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 20, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      S.noModelShortNotice,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const SettingsScreen()),
                    ),
                    child: const Text(S.importGguf),
                  ),
                ],
              ),
            ),
          if (models.loading)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      S.modelLoadingMessage,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (c.notice != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(8),
              child: Text(c.notice!),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  enabled: canSend,
                  decoration: InputDecoration(
                    hintText: c.generating
                        ? S.generating
                        : (models.loading
                            ? S.modelLoadingMessage
                            : (!hasModel
                                ? S.inputDisabledNoModel
                                : S.typeMessage)),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              c.generating
                  ? IconButton.filledTonal(
                      tooltip: S.stopGeneration,
                      icon: const Icon(Icons.stop),
                      onPressed: c.stop,
                    )
                  : IconButton.filled(
                      tooltip: S.send,
                      icon: const Icon(Icons.send),
                      onPressed: canSend ? () => _handleSend(c) : null,
                    ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m});
  final ChatMessage m;
  @override
  Widget build(BuildContext context) {
    final mine = m.role == MessageRole.user;
    final cs = Theme.of(context).colorScheme;
    final interrupted =
        !mine && m.status == MessageStatus.interrupted && m.content.isNotEmpty;
    return Align(
      alignment:
          mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m.content.isEmpty ? '...' : m.content),
          if (interrupted)
            Text(S.interruptedMark,
                style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  const _HistoryDrawer({required this.controller});
  final ChatController controller;

  Future<void> _confirmDeleteSingle(
      BuildContext context, Conversation conversation) async {
    if (controller.generating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(S.cannotDeleteWhileGenerating)),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.confirmDeleteChatTitle),
        content: Text(
            'هل أنت متأكد من حذف محادثة "${conversation.title}"؟ لا يمكن استرجاع الرسائل بعد حذفها.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(S.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(S.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.delete(conversation);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    if (controller.generating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(S.cannotDeleteWhileGenerating)),
      );
      return;
    }
    if (controller.conversations.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.confirmDeleteAllTitle),
        content: const Text(S.confirmDeleteAllBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(S.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(S.deleteAll),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final nav = Navigator.of(context);
      await controller.deleteAll();
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(children: [
          ListTile(
            title: const Text(S.history),
            trailing: IconButton(
              tooltip: S.deleteAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: controller.generating
                  ? null
                  : () => _confirmDeleteAll(context),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(children: [
              for (final c in controller.conversations)
                ListTile(
                  selected: c.id == controller.current?.id,
                  title:
                      Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    controller.open(c);
                    Navigator.of(context).pop();
                  },
                  trailing: IconButton(
                    tooltip: S.deleteChat,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: controller.generating
                        ? null
                        : () => _confirmDeleteSingle(context, c),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
