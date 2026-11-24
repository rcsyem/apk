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

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();
    final models = context.watch<ModelManager>();
    final modelName = models.active?.name ?? S.noModel;
    _scrollToEnd();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.current?.title ?? S.appName, overflow: TextOverflow.ellipsis),
          Text('${S.activeModel}: $modelName',
              style: Theme.of(context).textTheme.labelSmall, overflow: TextOverflow.ellipsis),
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
            child: c.messages.isEmpty
                ? const Center(child: Text(S.emptyChat))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: c.messages.length,
                    itemBuilder: (_, i) => _Bubble(m: c.messages[i]),
                  ),
          ),
          if (models.loading) const LinearProgressIndicator(),
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
                  enabled: !c.generating,
                  decoration: InputDecoration(
                      hintText: c.generating ? S.generating : S.typeMessage,
                      border: const OutlineInputBorder()),
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
                      onPressed: () {
                        final t = _input.text;
                        _input.clear();
                        c.send(t);
                      },
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
    final interrupted = !mine && m.status == MessageStatus.interrupted && m.content.isNotEmpty;
    return Align(
      // Directional alignment: "start" is the right edge in Arabic (RTL).
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m.content.isEmpty ? '...' : m.content),
          if (interrupted)
            Text(S.interruptedMark, style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  const _HistoryDrawer({required this.controller});
  final ChatController controller;
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
              onPressed: () async {
                final nav = Navigator.of(context);
                await controller.deleteAll();
                nav.pop();
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(children: [
              for (final c in controller.conversations)
                ListTile(
                  selected: c.id == controller.current?.id,
                  title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    controller.open(c);
                    Navigator.of(context).pop();
                  },
                  trailing: IconButton(
                    tooltip: S.deleteChat,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => controller.delete(c),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
