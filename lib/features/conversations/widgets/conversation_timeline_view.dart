import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../application/conversations/conversation_timeline.dart';
import '../../../core/domain/models.dart';
import '../../common/app_toast.dart';
import '../../common/sticky_detail_header.dart';

class ConversationTimelineBlockView extends StatelessWidget {
  const ConversationTimelineBlockView({
    super.key,
    required this.block,
    this.allowCopy = true,
  });

  final ConversationTimelineBlock block;
  final bool allowCopy;

  @override
  Widget build(BuildContext context) => switch (block) {
        UserMessageBlock value => _UserMessage(block: value),
        AssistantMessageBlock value => _AssistantMessage(block: value, allowCopy: allowCopy),
        TurnProcessBlock value => _TurnProcess(block: value),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (block.attachments.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final attachment in block.attachments)
                            _UserAttachmentLabel(attachment: attachment),
                        ],
                      ),
                    if (block.attachments.isNotEmpty && block.text.isNotEmpty)
                      const SizedBox(height: 8),
                    if (block.text.isNotEmpty)
                      _MarkdownContent(
                        data: block.text,
                        textStyle: Theme.of(context).textTheme.bodyLarge,
                      ),
                  ],
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }
}

class _UserAttachmentLabel extends StatelessWidget {
  const _UserAttachmentLabel({required this.attachment});

  final GatewayMessageContent attachment;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(attachment.uri ?? '');
    final fallback = switch (attachment.kind) {
      'image' => '图片附件',
      'audio' => '音频附件',
      _ => '文件附件',
    };
    final name = attachment.name?.trim();
    final label = name?.isNotEmpty == true
        ? name!
        : uri != null && uri.scheme != 'data' && uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last
            : fallback;
    return Tooltip(
      message: label,
      child: Chip(
        key: ValueKey('user-attachment-${attachment.id}'),
        avatar: Icon(switch (attachment.kind) {
          'image' => Icons.image_outlined,
          'audio' => Icons.audio_file_outlined,
          _ => Icons.insert_drive_file_outlined,
        }, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.block, required this.allowCopy});

  final AssistantMessageBlock block;
  final bool allowCopy;

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
                if (allowCopy && !block.isRunning) _CopyAction(text: block.text),
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

class _TurnProcess extends StatefulWidget {
  const _TurnProcess({required this.block});
  final TurnProcessBlock block;
  @override
  State<_TurnProcess> createState() => _TurnProcessState();
}

class _TurnProcessState extends State<_TurnProcess> {
  bool _expanded = false;
  final _headerKey = GlobalKey();

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final headerContext = _headerKey.currentContext;
        if (mounted && headerContext != null) {
          Scrollable.ensureVisible(headerContext,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        }
      });
    }
  }
  @override
  void didUpdateWidget(_TurnProcess oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.block.completed && widget.block.completed) _expanded = false;
  }
  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final duration = block.duration;
    final seconds = duration?.inSeconds;
    final label = seconds == null ? '执行过程' :
      '用时 ${seconds ~/ 60 > 0 ? '${seconds ~/ 60}分 ' : ''}${seconds % 60}秒';
    final expanded = !block.completed || _expanded;
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (expanded)
        for (final child in block.children)
          Padding(padding: const EdgeInsets.only(bottom: 4),
            child: ConversationTimelineBlockView(key: ValueKey(child.id), block: child, allowCopy: false)),
    ]);
    if (!block.completed) return content;
    final header = Material(
      key: _headerKey,
      color: Theme.of(context).scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      child: InkWell(
        key: Key('process-toggle-${block.id}'),
        onTap: _toggle,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Text(label, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(width: 4),
            Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18,
              color: Theme.of(context).colorScheme.outline),
          ]))),
    );
    return expanded ? StickyDetailHeader(header: header, content: content) : header;
  }
}

class FileChangeSummaryView extends StatelessWidget {
  const FileChangeSummaryView({super.key, required this.summary});
  final FileChangeSummary summary;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ActionChip(
      avatar: const Icon(Icons.difference_outlined, size: 16),
      label: Text('文件变更 · ${summary.count} 次'),
      onPressed: summary.details.isEmpty ? null : () => showModalBottomSheet<void>(
        context: context, showDragHandle: true, useSafeArea: true,
        builder: (context) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(summary.details.join('\n\n')),
        )),
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

class _CommandActivity extends StatelessWidget {
  const _CommandActivity({required this.block});

  final CommandBlock block;

  @override
  Widget build(BuildContext context) {
    return _ToolActivityLauncher(
      key: Key('timeline-command-${block.id}'),
      icon: Icons.terminal_outlined,
      title: block.tool?.name ?? block.title,
      command: block.tool?.input is GatewayCommandToolInput
        ? (block.tool!.input as GatewayCommandToolInput).command : block.command,
      status: block.status,
      running: block.isRunning,
      onOpen: () => _showToolDetails(
        context,
        icon: Icons.terminal_outlined,
        title: block.title,
        status: block.status,
        running: block.isRunning,
        child: _CommandDetails(block: block),
      ),
      approval: block.approval,
    );
  }
}

class _ToolActivity extends StatelessWidget {
  const _ToolActivity({required this.block});

  final ToolBlock block;

  @override
  Widget build(BuildContext context) {
    return _ToolActivityLauncher(
      icon: Icons.build_outlined,
      title: block.tool?.name ?? block.title,
      command: switch (block.tool?.input) {
        GatewayCommandToolInput input => input.command,
        GatewayStructuredToolInput input => jsonEncode(input.value),
        GatewayOpaqueToolInput input => input.value,
        _ => block.summary,
      },
      status: block.status,
      running: block.isRunning,
      onOpen: () => _showToolDetails(
        context,
        icon: Icons.build_outlined,
        title: block.title,
        status: block.status,
        running: block.isRunning,
        child: _ToolInvocationDetails(
          tool: block.tool,
          fallback: [block.summary, block.detail]
              .where((part) => part.isNotEmpty)
              .join('\n\n'),
        ),
      ),
      approval: block.approval,
    );
  }
}

class _ToolActivityLauncher extends StatelessWidget {
  const _ToolActivityLauncher({
    super.key,
    required this.icon,
    required this.title,
    required this.command,
    required this.status,
    required this.running,
    required this.onOpen,
    this.approval,
  });

  final IconData icon;
  final String title;
  final String command;
  final String? status;
  final bool running;
  final VoidCallback onOpen;
  final TimelineApproval? approval;

  @override
  Widget build(BuildContext context) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(children: [
                Icon(icon, size: 16, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 8),
                Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.outline))),
                if (command.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: Text(command.replaceAll('\n', ' '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.outline))),
                ] else const Spacer(),
                const SizedBox(width: 8),
                if (running)
                  SizedBox.square(dimension: 13, child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Theme.of(context).colorScheme.outline))
                else
                  Icon(status == 'failed' ? Icons.warning_amber_rounded :
                    status == 'completed' ? Icons.check : Icons.remove,
                    size: 16, semanticLabel: status == null ? null : _statusLabel(status!),
                    color: status == 'failed' ? Theme.of(context).colorScheme.error :
                      Theme.of(context).colorScheme.outline),
              ]),
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

void _showToolDetails(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String? status,
  required bool running,
  required Widget child,
}) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.68,
      minChildSize: 0.32,
      maxChildSize: 0.94,
      snap: true,
      snapSizes: const [0.68, 0.94],
      builder: (context, scrollController) => _ToolDetailSheet(
        icon: icon,
        title: title,
        status: status,
        running: running,
        scrollController: scrollController,
        child: child,
      ),
    ),
  );
}

class _ToolDetailSheet extends StatelessWidget {
  const _ToolDetailSheet({
    required this.icon,
    required this.title,
    required this.status,
    required this.running,
    required this.scrollController,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String? status;
  final bool running;
  final ScrollController scrollController;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const Key('tool-detail-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '工具详情',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
              ),
              if (running)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _StatusLabel(status: status!),
                ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _CommandDetails extends StatelessWidget {
  const _CommandDetails({required this.block});

  final CommandBlock block;

  @override
  Widget build(BuildContext context) {
    final input = block.tool?.input;
    final outcome = block.tool?.outcome;
    final commandInput = input is GatewayCommandToolInput ? input : null;
    final failure = outcome is GatewayToolFailure ? outcome : null;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (block.tool != null) ...[
            _ToolInvocationSummary(tool: block.tool!),
            const SizedBox(height: 18),
          ],
          if (block.command.isNotEmpty)
            _ToolDetailSection(label: '命令', text: block.command),
          if (block.command.isNotEmpty && block.output.isNotEmpty)
            const SizedBox(height: 18),
          if (block.output.isNotEmpty)
            _ToolDetailSection(label: '输出', text: block.output),
          if (commandInput?.actions.isNotEmpty == true) ...[
            const SizedBox(height: 18),
            _ToolDetailSection(
              label: '命令动作',
              text: commandInput!.actions
                  .map((action) => [
                        action.kind,
                        action.path ?? action.query ?? action.name,
                        action.command,
                      ].whereType<String>().join(' · '))
                  .join('\n'),
            ),
          ],
          if (failure?.error.message case final String error) ...[
            if (block.output.isNotEmpty || block.command.isNotEmpty)
              const SizedBox(height: 18),
            _ToolDetailSection(label: '错误', text: error),
          ],
          if (block.command.isEmpty && block.output.isEmpty)
            Text(
              '暂无详情',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
        ],
      );
  }
}

class _ToolInvocationDetails extends StatelessWidget {
  const _ToolInvocationDetails({required this.tool, required this.fallback});

  final GatewayToolInvocation? tool;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final tool = this.tool;
    if (tool == null) {
      return fallback.isEmpty
          ? Text(
              '暂无详情',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          : _MarkdownContent(data: fallback);
    }
    final inputValue = switch (tool.input) {
      GatewayCommandToolInput value => [
          value.command,
          if (value.cwd != null) 'cwd: ${value.cwd}',
          if (value.shell != null) 'shell: ${value.shell}',
        ].join('\n'),
      GatewayStructuredToolInput value =>
        const JsonEncoder.withIndent('  ').convert(value.value),
      GatewayOpaqueToolInput value => value.value,
    };
    final inputTruncation = switch (tool.input) {
      GatewayStructuredToolInput value => value.truncation,
      GatewayOpaqueToolInput value => value.truncation,
      GatewayCommandToolInput value => value.truncation,
    };
    final input = inputTruncation == null
        ? inputValue
        : '$inputValue\n[内容已截断：originalBytes=${inputTruncation.originalBytes}, '
            'retainedBytes=${inputTruncation.retainedBytes}, '
            'strategy=${inputTruncation.strategy}]';
    final outcome = tool.outcome;
    final result = (outcome?.content ?? const <GatewayMessageContent>[])
        .map((content) {
          final value = content.displayText;
          final truncation = content.truncation;
          if (truncation == null) return value;
          return '$value\n[内容已截断：originalBytes=${truncation.originalBytes}, '
              'retainedBytes=${truncation.retainedBytes}, '
              'strategy=${truncation.strategy}]';
        })
        .where((value) => value.isNotEmpty)
        .join('\n\n');
    final failure = outcome is GatewayToolFailure ? outcome : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ToolInvocationSummary(tool: tool),
        if (input.isNotEmpty) ...[
          const SizedBox(height: 18),
          _ToolDetailSection(label: '参数', text: input),
        ],
        if (result.isNotEmpty) ...[
          const SizedBox(height: 18),
          _ToolDetailSection(label: '结果', text: result),
        ],
        if (failure?.error.message case final String error) ...[
          const SizedBox(height: 18),
          _ToolDetailSection(label: '错误', text: error),
        ],
        if (input.isEmpty &&
            result.isEmpty &&
            failure == null &&
            fallback.isNotEmpty) ...[
          const SizedBox(height: 18),
          _MarkdownContent(data: fallback),
        ],
      ],
    );
  }
}

class _ToolInvocationSummary extends StatelessWidget {
  const _ToolInvocationSummary({required this.tool});

  final GatewayToolInvocation tool;

  @override
  Widget build(BuildContext context) {
    final source = [tool.originKind, tool.originName]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .join(' · ');
    final duration = tool.durationMs == null ? null : '${tool.durationMs} ms';
    final commandInput =
        tool.input is GatewayCommandToolInput
            ? tool.input as GatewayCommandToolInput
            : null;
    final outcome = tool.outcome;
    final details = <String>[
      '调用：${tool.namespace == null ? tool.name : '${tool.namespace}/${tool.name}'}',
      '来源：$source',
      '类别：${tool.category}',
      if (commandInput?.cwd != null) '目录：${commandInput!.cwd}',
      if (outcome?.exitCode != null) '退出码：${outcome!.exitCode}',
      if (outcome?.processId != null) '进程：${outcome!.processId}',
      if (duration != null) '耗时：$duration',
      if (tool.readOnly != null) '只读：${tool.readOnly! ? '是' : '否'}',
      if (tool.destructive != null) '破坏性：${tool.destructive! ? '是' : '否'}',
      if (tool.idempotent != null) '幂等：${tool.idempotent! ? '是' : '否'}',
      if (tool.openWorld != null) '访问外部世界：${tool.openWorld! ? '是' : '否'}',
    ];
    return _ToolDetailSection(label: '概览', text: details.join('\n'));
  }
}

class _ToolDetailSection extends StatelessWidget {
  const _ToolDetailSection({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
        key: Key(
          'tool-detail-${label == '命令' ? 'command' : label == '输出' ? 'output' : label}',
        ),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          _CodePanel(text: text),
        ],
      );
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

  Future<void> _openLink(String? href) async {
    if (href == null || href.trim().isEmpty) return;
    final uri = Uri.tryParse(href.trim());
    if (uri == null ||
        !const {'http', 'https', 'mailto', 'tel', 'sms'}.contains(uri.scheme) ||
        ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isEmpty)) {
      AppToast.show(
        type: AppToastType.warning,
        content: const TextSpan(text: '此链接无法在当前设备打开'),
      );
      return;
    }
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // The platform may throw instead of returning false when no app handles it.
    }
    if (!mounted) return;
    AppToast.show(
      type: AppToastType.error,
      content: const TextSpan(text: '无法打开链接，请复制链接后重试'),
    );
  }

  void _cacheMarkdown() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = widget.textStyle ?? theme.textTheme.bodyMedium!;
    _cachedMarkdown = MarkdownBody(
      data: widget.data,
      fitContent: false,
      softLineBreak: true,
      onTapLink: (text, href, title) => _openLink(href),
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
    required this.icon,
    required this.title,
    required this.status,
    required this.running,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String? status;
  final bool running;
  final bool expanded;
  final VoidCallback? onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActivityHeader(
          icon: icon,
          title: title,
          status: status,
          running: running,
          onTap: onToggle,
          expanded: expanded,
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
      ],
    );
  }
}

class _ActivityHeader extends StatelessWidget {
  const _ActivityHeader({
    required this.icon,
    required this.title,
    required this.status,
    required this.running,
    required this.onTap,
    required this.expanded,
  });

  final IconData icon;
  final String title;
  final String? status;
  final bool running;
  final VoidCallback? onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
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
            if (onTap != null)
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
          ],
        ),
      ),
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
