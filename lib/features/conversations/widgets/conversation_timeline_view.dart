import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../application/conversations/conversation_timeline.dart';
import '../../common/app_toast.dart';

class ConversationTimelineBlockView extends StatelessWidget {
  const ConversationTimelineBlockView({
    super.key,
    required this.block,
  });

  final ConversationTimelineBlock block;

  @override
  Widget build(BuildContext context) => switch (block) {
        UserMessageBlock value => _UserMessage(block: value),
        AssistantMessageBlock value => _AssistantMessage(block: value),
        ReasoningBlock value => _ReasoningActivity(block: value),
        CommandBlock value => _CommandActivity(block: value),
        ToolBlock value => _ToolActivity(block: value),
        FileChangesBlock value => _FileChangesActivity(block: value),
        ApprovalBlock value => _ApprovalActivity(block: value),
        UnknownActivityBlock value => _UnknownActivity(block: value),
      };
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.block});

  final UserMessageBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: _MarkdownContent(
                  data: block.text,
                  textStyle: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            _CopyAction(text: block.text),
          ],
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.block});

  final AssistantMessageBlock block;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MarkdownContent(
              data: block.text,
              textStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.55,
                  ),
            ),
            Row(
              children: [
                _CopyAction(text: block.text),
                if (block.isRunning) ...[
                  const SizedBox(width: 4),
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
}

class _ReasoningActivity extends StatefulWidget {
  const _ReasoningActivity({required this.block});

  final ReasoningBlock block;

  @override
  State<_ReasoningActivity> createState() => _ReasoningActivityState();
}

class _ReasoningActivityState extends State<_ReasoningActivity> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => _ExpandableActivity(
        icon: Icons.psychology_outlined,
        title: widget.block.isRunning ? '正在思考' : '思考过程',
        status: widget.block.status,
        running: widget.block.isRunning,
        expanded: _expanded,
        onToggle: () => setState(() => _expanded = !_expanded),
        child: _MarkdownContent(data: widget.block.summary),
      );
}

class _CommandActivity extends StatefulWidget {
  const _CommandActivity({required this.block});

  final CommandBlock block;

  @override
  State<_CommandActivity> createState() => _CommandActivityState();
}

class _CommandActivityState extends State<_CommandActivity> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final content = [
      if (block.command.isNotEmpty) block.command,
      if (block.output.isNotEmpty) block.output,
    ].join('\n\n');
    return _ExpandableActivity(
      key: Key('timeline-command-${block.id}'),
      icon: Icons.terminal_outlined,
      title: block.title,
      status: block.status,
      running: block.isRunning,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      approval: block.approval,
      child: _CodePanel(text: content),
    );
  }
}

class _ToolActivity extends StatefulWidget {
  const _ToolActivity({required this.block});

  final ToolBlock block;

  @override
  State<_ToolActivity> createState() => _ToolActivityState();
}

class _ToolActivityState extends State<_ToolActivity> {
  late bool _expanded = widget.block.isRunning;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final detail = [block.summary, block.detail]
        .where((part) => part.isNotEmpty)
        .join('\n\n');
    return _ExpandableActivity(
      icon: Icons.build_outlined,
      title: block.title,
      status: block.status,
      running: block.isRunning,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      approval: block.approval,
      child: _MarkdownContent(data: detail),
    );
  }
}

class _FileChangesActivity extends StatelessWidget {
  const _FileChangesActivity({required this.block});

  final FileChangesBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.center,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.difference_outlined, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  block.summary.isEmpty
                      ? block.title
                      : '${block.title}  ${block.summary}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (block.isRunning) ...[
                const SizedBox(width: 10),
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalActivity extends StatelessWidget {
  const _ApprovalActivity({required this.block});

  final ApprovalBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.approval_outlined, size: 19),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    block.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (block.status != null) _StatusLabel(status: block.status!),
              ],
            ),
            if (block.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              _MarkdownContent(data: block.description),
            ],
          ],
        ),
      ),
    );
  }
}

class _UnknownActivity extends StatelessWidget {
  const _UnknownActivity({required this.block});

  final UnknownActivityBlock block;

  @override
  Widget build(BuildContext context) => _ExpandableActivity(
        icon: Icons.info_outline,
        title: block.title,
        status: block.status,
        running: block.isRunning,
        expanded: true,
        onToggle: null,
        child: _MarkdownContent(data: block.detail),
      );
}

class _MarkdownContent extends StatefulWidget {
  const _MarkdownContent({
    required this.data,
    this.textStyle,
  });

  final String data;
  final TextStyle? textStyle;

  @override
  State<_MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends State<_MarkdownContent> {
  MarkdownBody? _cachedMarkdown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheMarkdown();
  }

  @override
  void didUpdateWidget(_MarkdownContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.textStyle != widget.textStyle) {
      _cacheMarkdown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(child: _cachedMarkdown!);
  }

  void _cacheMarkdown() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = widget.textStyle ?? theme.textTheme.bodyMedium!;
    _cachedMarkdown = MarkdownBody(
      data: widget.data,
      fitContent: false,
      softLineBreak: true,
      imageBuilder: (uri, title, alt) => Tooltip(
        message: uri.toString(),
        child: Text(
          alt == null || alt.isEmpty ? '[图片]' : '[图片：$alt]',
          style: body.copyWith(
            color: colors.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        pPadding: EdgeInsets.zero,
        blockSpacing: 10,
        listBullet: body,
        code: body.copyWith(
          fontFamily: 'monospace',
          fontSize: (body.fontSize ?? 14) * 0.9,
          backgroundColor: colors.surfaceContainerHighest,
        ),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border(
            left: BorderSide(color: colors.primary, width: 3),
          ),
        ),
        tableBorder: TableBorder.all(color: colors.outlineVariant),
      ),
    );
  }
}

class _ExpandableActivity extends StatelessWidget {
  const _ExpandableActivity({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.running,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.approval,
  });

  final IconData icon;
  final String title;
  final String? status;
  final bool running;
  final bool expanded;
  final VoidCallback? onToggle;
  final Widget child;
  final TimelineApproval? approval;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 19, color: colors.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (running)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox.square(
                      dimension: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _StatusLabel(status: status!),
                  ),
                if (onToggle != null)
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 160),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
            child: child,
          ),
        ),
        if (approval != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
            child: _AttachedApproval(approval: approval!),
          ),
      ],
    );
  }
}

class _AttachedApproval extends StatelessWidget {
  const _AttachedApproval({required this.approval});

  final TimelineApproval approval;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.approval_outlined, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                approval.description?.isNotEmpty == true
                    ? '${approval.title} · ${approval.description}'
                    : approval.title,
              ),
            ),
            if (approval.status != null)
              _StatusLabel(status: approval.status!),
          ],
        ),
      ),
    );
  }
}

class _CodePanel extends StatelessWidget {
  const _CodePanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (text.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectionArea(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    height: 1.45,
                  ),
                ),
              ),
            ),
            _CopyAction(text: text),
          ],
        ),
      ),
    );
  }
}

class _CopyAction extends StatelessWidget {
  const _CopyAction({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        tooltip: '复制',
        onPressed: text.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!context.mounted) return;
                AppToast.show(
                  type: AppToastType.success,
                  duration: const Duration(seconds: 2),
                  content: const TextSpan(
                    children: [
                      TextSpan(
                        text: '已复制',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: '到剪贴板'),
                    ],
                  ),
                );
              },
        icon: const Icon(Icons.copy_outlined),
      );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) => Text(
        _statusLabel(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
}

String _statusLabel(String status) => switch (status) {
      'pending' => '等待中',
      'running' => '进行中',
      'completed' => '已完成',
      'failed' => '失败',
      'interrupted' => '已中断',
      'declined' => '已拒绝',
      'approved' => '已批准',
      'denied' => '已拒绝',
      'expired' => '已过期',
      _ => status,
    };
