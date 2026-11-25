import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../application/chat_controller.dart';
import '../../data/models.dart';
import '../../models/model_manager.dart';
import '../strings_ar.dart';
import '../utils/date_formatter.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.onNavigateToSettings,
  });

  final VoidCallback? onNavigateToSettings;

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
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend(ChatController c) async {
    final text = _input.text.trim();
    if (text.isEmpty || _isSubmitting || c.generating || !c.canSend) return;
    setState(() => _isSubmitting = true);
    _input.clear();
    try {
      await c.send(text);
      _scrollToEnd();
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _applySuggestion(String text) {
    _input.text = text;
    _input.selection = TextSelection.fromPosition(
      TextPosition(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = context.watch<ChatController>();
    final models = context.watch<ModelManager>();

    final hasModel = models.active != null;
    final modelName = models.active?.name ?? S.noModel;
    final isModelReady = hasModel && !models.loading;
    final canSend = isModelReady && !c.generating && !_isSubmitting;

    // Trigger auto-scroll on generating new tokens
    if (c.generating) {
      _scrollToEnd();
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.current?.title ?? S.appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isModelReady
                        ? Colors.green
                        : (models.loading ? Colors.blue : Colors.amber),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    modelName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: S.newChat,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: c.generating ? null : () => c.newConversation(),
          ),
          if (widget.onNavigateToSettings != null)
            IconButton(
              tooltip: S.settings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: widget.onNavigateToSettings,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Status bar for loading or no model
            if (models.loading)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: cs.secondaryContainer,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        S.modelLoadingMessage,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (!hasModel)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: cs.errorContainer.withOpacity(0.5),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.noModelShortNotice,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onErrorContainer,
                        ),
                      ),
                    ),
                    if (widget.onNavigateToSettings != null)
                      TextButton(
                        onPressed: widget.onNavigateToSettings,
                        child: const Text(S.goToImportModel),
                      ),
                  ],
                ),
              ),

            if (c.notice != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: cs.errorContainer,
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: cs.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.notice!,
                        style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

            // Message Area
            Expanded(
              child: c.messages.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: cs.primaryContainer,
                              ),
                              child: Icon(
                                Icons.chat_bubble_outline,
                                size: 48,
                                color: cs.primary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              S.emptyChat,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              S.emptyChatDesc,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                S.suggestionsTitle,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _SuggestionChip(
                              text: S.suggestion1,
                              onTap: () => _applySuggestion(S.suggestion1),
                            ),
                            _SuggestionChip(
                              text: S.suggestion2,
                              onTap: () => _applySuggestion(S.suggestion2),
                            ),
                            _SuggestionChip(
                              text: S.suggestion3,
                              onTap: () => _applySuggestion(S.suggestion3),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      itemCount: c.messages.length + (c.generating ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index < c.messages.length) {
                          return _MessageBubble(m: c.messages[index]);
                        } else {
                          // Generating indicator tile
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  S.generating,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  icon: const Icon(Icons.stop, size: 16),
                                  label: const Text(S.stopGeneration),
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: cs.error,
                                  ),
                                  onPressed: c.stop,
                                ),
                              ],
                            ),
                          );
                        }
                      },
                    ),
            ),

            // Input Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    offset: const Offset(0, -1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textDirection: TextDirection.rtl,
                      enabled: isModelReady && !c.generating,
                      decoration: InputDecoration(
                        hintText: c.generating
                            ? S.generating
                            : (!hasModel
                                ? S.inputDisabledNoModel
                                : (models.loading
                                    ? S.modelLoadingMessage
                                    : S.typeMessage)),
                        hintStyle: TextStyle(
                          color: cs.onSurfaceVariant.withOpacity(0.7),
                          fontSize: 14,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(color: cs.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(color: cs.primary, width: 1.5),
                        ),
                      ),
                      onSubmitted: (_) {
                        if (canSend) _handleSend(c);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (c.generating)
                    IconButton.filledTonal(
                      tooltip: S.stopGeneration,
                      icon: const Icon(Icons.stop),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.errorContainer,
                        foregroundColor: cs.onErrorContainer,
                      ),
                      onPressed: c.stop,
                    )
                  else
                    IconButton.filled(
                      tooltip: canSend ? S.send : S.cannotSendNotice,
                      icon: const Icon(Icons.send_rounded),
                      onPressed: canSend ? () => _handleSend(c) : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: BorderSide(color: cs.outlineVariant),
        ),
        onPressed: onTap,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface,
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.m});
  final ChatMessage m;

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(S.copiedToClipboard),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = m.role == MessageRole.user;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final interrupted =
        !mine && m.status == MessageStatus.interrupted && m.content.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: cs.secondaryContainer,
              child: Icon(Icons.smart_toy_outlined,
                  size: 18, color: cs.onSecondaryContainer),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: mine ? cs.primaryContainer : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 4 : 16),
                  bottomRight: Radius.circular(mine ? 16 : 4),
                ),
                border: Border.all(
                  color: mine ? Colors.transparent : cs.outlineVariant,
                  width: 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mine ? S.userRole : S.assistantRole,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: mine ? cs.onPrimaryContainer : cs.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        ArabicDateFormatter.formatTime(m.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant.withOpacity(0.6),
                          fontSize: 10,
                        ),
                      ),
                      if (!mine && m.content.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _copy(context, m.content),
                          child: Icon(
                            Icons.copy_outlined,
                            size: 14,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    m.content.isEmpty ? '...' : m.content,
                    textDirection: TextDirection.rtl,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: mine ? cs.onPrimaryContainer : cs.onSurface,
                      height: 1.5,
                      fontSize: 14.5,
                    ),
                  ),
                  if (interrupted) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cs.errorContainer.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        S.interruptedMark,
                        style: TextStyle(fontSize: 11, color: cs.error),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (mine) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: cs.primary,
              child: Icon(Icons.person_outline, size: 18, color: cs.onPrimary),
            ),
          ],
        ],
      ),
    );
  }
}
