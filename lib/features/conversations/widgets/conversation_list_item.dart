import 'package:flutter/material.dart';

import '../../../core/domain/models.dart';
import '../../../application/sessions/device_session.dart';

/// Shared list layout for home, project, chat and search results.
class ConversationList extends StatelessWidget {
  const ConversationList({
    super.key,
    required this.conversations,
    required this.onTap,
    required this.itemKey,
    this.leading = const [],
    this.trailing = const [],
    this.embedded = false,
    this.padding = const EdgeInsets.all(16),
  });

  final List<ConversationSummary> conversations;
  final ValueChanged<ConversationSummary> onTap;
  final Key Function(ConversationSummary) itemKey;
  final List<Widget> leading;
  final List<Widget> trailing;
  final bool embedded;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListView.separated(
    shrinkWrap: embedded,
    primary: embedded ? false : null,
    physics: embedded ? const NeverScrollableScrollPhysics() : null,
    padding: padding,
    itemCount: leading.length + conversations.length + trailing.length,
    separatorBuilder: (_, _) => const SizedBox(height: 8),
    itemBuilder: (_, index) {
      if (index < leading.length) return leading[index];
      final dataIndex = index - leading.length;
      if (dataIndex >= conversations.length) {
        return trailing[dataIndex - conversations.length];
      }
      final conversation = conversations[dataIndex];
      return ConversationListItem(
        key: itemKey(conversation),
        conversation: conversation,
        onTap: onTap,
      );
    },
  );
}

class ConversationListItem extends StatelessWidget {
  const ConversationListItem({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final ValueChanged<ConversationSummary> onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    child: _ConversationTile(
      key: Key('conversation-${conversation.id}'),
      conversation: conversation,
      onTap: () => onTap(conversation),
    ),
  );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: conversation.readState.unread
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                      ),
                    ),
                    ConversationIndicators(
                      running: conversationIsInProgress(conversation),
                      unread: conversation.readState.unread,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (conversation.preview != null)
                  Text(
                    conversation.preview!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  HeadTailPath(conversation.workspaceRoot ?? '无 workspaceRoot'),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Match the title line height to keep the timestamp centered with it.
          Text(
            relativeConversationTime(conversation.updatedAt),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class ConversationIndicators extends StatelessWidget {
  const ConversationIndicators({
    super.key,
    required this.running,
    required this.unread,
  });
  final bool running;
  final bool unread;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (running)
        const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Tooltip(
            message: '运行中',
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: '运行中',
              ),
            ),
          ),
        ),
      if (unread)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Semantics(
            label: '未读',
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue,
              ),
            ),
          ),
        ),
    ],
  );
}

class HeadTailPath extends StatelessWidget {
  const HeadTailPath(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        final characters = path.characters;
        String shortened(int length) {
          if (length >= characters.length) return path;
          final head = (length / 2).ceil();
          return '${characters.take(head)}…${characters.skip(characters.length - (length - head))}';
        }

        final painter = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        );
        var low = 0;
        var high = characters.length;
        while (low < high) {
          final mid = (low + high + 1) ~/ 2;
          painter.text = TextSpan(text: shortened(mid), style: style);
          painter.layout();
          if (painter.width <= constraints.maxWidth) {
            low = mid;
          } else {
            high = mid - 1;
          }
        }
        painter.dispose();
        return Tooltip(
          message: path,
          child: Text(
            shortened(low),
            semanticsLabel: path,
            maxLines: 1,
            style: style,
          ),
        );
      },
    );
  }
}

String relativeConversationTime(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(current.year, current.month, current.day);
  final difference = today.difference(day).inDays;
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (difference == 0) return time;
  if (difference == 1) return '昨天';
  if (difference < 7 && difference > 1) return '$difference 天前';
  return '${local.month}/${local.day}';
}
