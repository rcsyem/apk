import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../application/chat_controller.dart';
import '../../data/models.dart';
import '../../models/model_manager.dart';
import '../strings_ar.dart';
import '../utils/date_formatter.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.onNavigateToTab,
  });

  /// Navigation callback: 0=Home, 1=Chat, 2=Conversations, 3=Settings
  final void Function(int index) onNavigateToTab;

  Future<void> _startNewChat(BuildContext context, ChatController controller) async {
    if (controller.generating) return;
    await controller.newConversation();
    onNavigateToTab(1); // Go to Chat tab
  }

  Future<void> _openChat(
      BuildContext context, ChatController controller, Conversation c) async {
    if (controller.generating) return;
    await controller.open(c);
    onNavigateToTab(1); // Go to Chat tab
  }

  Future<void> _confirmDeleteChat(
      BuildContext context, ChatController controller, Conversation c) async {
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
            'هل أنت متأكد من حذف محادثة "${c.title}"؟ لا يمكن استرجاع الرسائل بعد حذفها.'),
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
      await controller.delete(c);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final chat = context.watch<ChatController>();
    final models = context.watch<ModelManager>();

    final hasModel = models.active != null;
    final modelName = models.active?.name ?? S.noModel;
    final isReady = hasModel && !models.loading;

    // Recent conversations (up to 4)
    final recentList = chat.conversations.take(4).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.psychology_outlined, color: cs.primary),
            const SizedBox(width: 8),
            const Text(S.appName),
          ],
        ),
        actions: [
          IconButton(
            tooltip: S.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => onNavigateToTab(3),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => chat.refresh(),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // 1. Model Status Card
              Card(
                elevation: 0,
                color: cs.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isReady
                        ? Colors.green.shade300
                        : (models.loading ? Colors.blue.shade300 : cs.outlineVariant),
                    width: 1.2,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isReady
                                    ? Icons.check_circle_outline
                                    : (models.loading
                                        ? Icons.sync
                                        : Icons.info_outline),
                                color: isReady
                                    ? Colors.green.shade700
                                    : (models.loading
                                        ? Colors.blue.shade700
                                        : Colors.amber.shade800),
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                S.activeModel,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isReady
                                  ? Colors.green.shade50
                                  : (models.loading
                                      ? Colors.blue.shade50
                                      : Colors.amber.shade50),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isReady
                                    ? Colors.green.shade300
                                    : (models.loading
                                        ? Colors.blue.shade300
                                        : Colors.amber.shade300),
                              ),
                            ),
                            child: Text(
                              isReady
                                  ? S.modelReadyBadge
                                  : (models.loading
                                      ? S.modelLoadingBadge
                                      : S.modelUnloadedBadge),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isReady
                                    ? Colors.green.shade800
                                    : (models.loading
                                        ? Colors.blue.shade800
                                        : Colors.amber.shade900),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        modelName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (models.loading) ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 4),
                        Text(
                          S.modelLoadingMessage,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            hasModel
                                ? '${(models.active!.sizeBytes / (1024 * 1024)).toStringAsFixed(0)} ميغابايت'
                                : 'اختر نموذجاً للبدء',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.tune, size: 16),
                            label: const Text(S.manageModels),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                            ),
                            onPressed: () => onNavigateToTab(3),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 2. Primary Action: Start New Chat
              FilledButton.icon(
                icon: const Icon(Icons.add_comment_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    S.startNewChatAction,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: chat.generating ? null : () => _startNewChat(context, chat),
              ),

              const SizedBox(height: 20),

              // 3. Recent Conversations Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    S.recentConversations,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (chat.conversations.isNotEmpty)
                    TextButton(
                      onPressed: () => onNavigateToTab(2), // Go to Conversations tab
                      child: const Text(S.viewAll),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Recent Conversations List
              if (recentList.isEmpty)
                Card(
                  elevation: 0,
                  color: cs.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: cs.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                    child: Column(
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 40, color: cs.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text(
                          S.noRecentConversations,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...recentList.map((c) {
                  final isCurrent = c.id == chat.current?.id;
                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
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
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor: cs.primaryContainer,
                        child: Icon(Icons.chat_outlined,
                            size: 18, color: cs.primary),
                      ),
                      title: Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
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
                        onPressed: chat.generating
                            ? null
                            : () => _confirmDeleteChat(context, chat, c),
                      ),
                      onTap: () => _openChat(context, chat, c),
                    ),
                  );
                }),

              const SizedBox(height: 20),

              // 4. Privacy & Offline Guarantee Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.tertiary.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.security_outlined, color: cs.tertiary, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.localAiBadge,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.tertiary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            S.offlineDesc,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
