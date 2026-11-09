import 'package:flutter/material.dart';

import '../../../core/domain/conversation_input_queue.dart';

class ConversationInputQueueView extends StatelessWidget {
  const ConversationInputQueueView({
    super.key,
    required this.queue,
    required this.enabled,
    required this.canSteer,
    required this.onSteer,
    required this.onEdit,
    required this.onDelete,
    required this.onRestore,
    required this.onResume,
    required this.onRefresh,
    this.error,
    this.notice,
  });
  final ConversationInputQueue? queue;
  final bool enabled;
  final bool canSteer;
  final void Function(ConversationQueuedInput) onSteer,
      onEdit,
      onDelete,
      onRestore;
  final VoidCallback onResume, onRefresh;
  final String? error, notice;
  @override
  Widget build(BuildContext context) {
    final snapshot = queue;
    final count = snapshot?.items.length ?? 0;
    final edits =
        snapshot?.recoverableEdits ?? const <ConversationQueuedInput>[];
    if (count == 0 && edits.isEmpty && error == null && notice == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (count > 0 || edits.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .22,
            ),
            child: SingleChildScrollView(
              key: const Key('input-queue-scroll'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item
                      in snapshot?.items ?? const <ConversationQueuedInput>[])
                    Container(
                      key: ValueKey('queue-item-${item.id}'),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(item.text.replaceAll(RegExp(r'\s+'), ' ').trim(), maxLines: 1,
                                overflow: TextOverflow.ellipsis)),
                              PopupMenuButton<String>(
                                key: ValueKey('queue-menu-${item.id}'),
                                tooltip: '消息操作',
                                padding: EdgeInsets.zero,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(32, 32),
                                  padding: EdgeInsets.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: Icon(Icons.keyboard_arrow_down,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: .45)),
                                onSelected: (action) {
                                  switch (action) {
                                    case 'steer': onSteer(item);
                                    case 'edit': onEdit(item);
                                    case 'delete': onDelete(item);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'steer',
                                    key: ValueKey('queue-steer-${item.id}'),
                                    enabled: enabled && canSteer && item.editable,
                                    child: const Text('引导')),
                                  PopupMenuItem(value: 'edit',
                                    key: ValueKey('queue-edit-${item.id}'),
                                    enabled: enabled && item.editable,
                                    child: const Text('重新编辑')),
                                  PopupMenuItem(value: 'delete',
                                    key: ValueKey('queue-delete-${item.id}'),
                                    enabled: enabled && (item.editable || item.uncertain),
                                    child: Text(item.uncertain ? '核对后移除' : '删除')),
                                ],
                              ),
                            ],
                          ),
                          if (!item.editable)
                            Text(switch (item.state) {
                              'outcomeUnknown' => '发送结果未知，请核对会话后移除记录。',
                              'steering' => '正在引导当前任务…',
                              _ => '正在发送…',
                            }, style: Theme.of(context).textTheme.bodySmall),
                          if (item.errorMessage != null)
                            Text(
                              item.errorMessage!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                        ],
                      ),
                    ),
                  for (final item in edits)
                    ListTile(
                      key: ValueKey('queue-recover-${item.id}'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: Text(
                        item.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('已撤回，尚未确认恢复到输入框'),
                      trailing: TextButton(
                        onPressed: enabled ? () => onRestore(item) : null,
                        child: const Text('恢复编辑'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (error != null)
          Text(
            error!,
            key: const Key('input-queue-error'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        if (notice != null)
          Text(
            notice!,
            key: const Key('input-queue-notice'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}
