import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../application/chat_controller.dart';
import '../../data/models.dart';
import '../strings_ar.dart';
import '../utils/date_formatter.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({
    super.key,
    required this.onNavigateToChat,
  });

  final VoidCallback onNavigateToChat;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  final _searchController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startNewChat(ChatController controller) async {
    if (controller.generating) return;
    await controller.newConversation();
    widget.onNavigateToChat();
  }

  Future<void> _openChat(ChatController controller, Conversation c) async {
    if (controller.generating) return;
    await controller.open(c);
    widget.onNavigateToChat();
  }

  Future<void> _confirmDeleteSingle(
      BuildContext context, ChatController controller, Conversation conversation) async {
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

  Future<void> _confirmDeleteAll(
      BuildContext context, ChatController controller) async {
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
      await controller.deleteAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final controller = context.watch<ChatController>();

    final allConversations = controller.conversations;
    final filteredConversations = _filter.isEmpty
        ? allConversations
        : allConversations
            .where((c) => c.title.toLowerCase().contains(_filter.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(S.conversations),
        actions: [
          IconButton(
            tooltip: S.deleteAll,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: controller.generating || allConversations.isEmpty
                ? null
                : () => _confirmDeleteAll(context, controller),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text(S.newChat),
        onPressed: controller.generating ? null : () => _startNewChat(controller),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search Bar
            if (allConversations.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _filter = val.trim()),
                  decoration: InputDecoration(
                    hintText: S.searchConversations,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _filter.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _filter = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),

            // Content
            Expanded(
              child: allConversations.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.forum_outlined,
                              size: 64, color: cs.onSurfaceVariant),
                          const SizedBox(height: 16),
                          Text(
                            S.noRecentConversations,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            S.emptyChatDesc,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text(S.startNewChatAction),
                            onPressed: () => _startNewChat(controller),
                          ),
                        ],
                      ),
                    )
                  : (filteredConversations.isEmpty
                      ? Center(
                          child: Text(
                            S.noConversationsFound,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                          itemCount: filteredConversations.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final c = filteredConversations[index];
                            final isCurrent = c.id == controller.current?.id;
                            return Card(
                              elevation: 0,
                              color: isCurrent
                                  ? cs.primaryContainer.withOpacity(0.4)
                                  : cs.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: isCurrent ? cs.primary : cs.outlineVariant,
                                  width: isCurrent ? 1.5 : 0.8,
                                ),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isCurrent
                                      ? cs.primary
                                      : cs.surfaceContainerHighest,
                                  foregroundColor: isCurrent
                                      ? cs.onPrimary
                                      : cs.onSurfaceVariant,
                                  child: const Icon(Icons.chat_bubble_outline,
                                      size: 18),
                                ),
                                title: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  ArabicDateFormatter.format(c.updatedAt),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                trailing: IconButton(
                                  tooltip: S.deleteChat,
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: controller.generating
                                      ? null
                                      : () => _confirmDeleteSingle(
                                          context, controller, c),
                                ),
                                onTap: () => _openChat(controller, c),
                              ),
                            );
                          },
                        )),
            ),
          ],
        ),
      ),
    );
  }
}
