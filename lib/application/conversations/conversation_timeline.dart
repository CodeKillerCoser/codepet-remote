import '../../core/domain/models.dart';

sealed class ConversationTimelineBlock {
  const ConversationTimelineBlock({
    required this.id,
    required this.turnId,
    required this.sourceItemIds,
    required this.isStreaming,
    this.status,
  });

  final String id;
  final String turnId;
  final List<String> sourceItemIds;
  final bool isStreaming;
  final String? status;

  bool get isRunning => isStreaming || status == 'running' || status == 'pending';
}

final class UserMessageBlock extends ConversationTimelineBlock {
  const UserMessageBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.text,
    super.status,
  });

  final String text;
}

final class AssistantMessageBlock extends ConversationTimelineBlock {
  const AssistantMessageBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.text,
    super.status,
  });

  final String text;

  AssistantMessageBlock append(AssistantMessageBlock other) =>
      AssistantMessageBlock(
        id: id,
        turnId: turnId,
        sourceItemIds: [...sourceItemIds, ...other.sourceItemIds],
        isStreaming: isStreaming || other.isStreaming,
        text: [text, other.text].where((part) => part.isNotEmpty).join('\n\n'),
        status: other.status ?? status,
      );
}

final class ReasoningBlock extends ConversationTimelineBlock {
  const ReasoningBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.summary,
    super.status,
  });

  final String summary;
}

final class TimelineApproval {
  const TimelineApproval({
    required this.id,
    required this.title,
    required this.status,
    this.description,
  });

  final String id;
  final String title;
  final String? description;
  final String? status;
}

final class CommandBlock extends ConversationTimelineBlock {
  const CommandBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.title,
    required this.command,
    required this.output,
    this.tool,
    this.approval,
    super.status,
  });

  final String title;
  final String command;
  final String output;
  final GatewayToolInvocation? tool;
  final TimelineApproval? approval;
}

final class ToolBlock extends ConversationTimelineBlock {
  const ToolBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.title,
    required this.summary,
    required this.detail,
    this.tool,
    this.approval,
    super.status,
  });

  final String title;
  final String summary;
  final String detail;
  final GatewayToolInvocation? tool;
  final TimelineApproval? approval;
}

final class FileChangesBlock extends ConversationTimelineBlock {
  const FileChangesBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.title,
    required this.summary,
    super.status,
  });

  final String title;
  final String summary;
}

final class ApprovalBlock extends ConversationTimelineBlock {
  const ApprovalBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.title,
    required this.description,
    super.status,
  });

  final String title;
  final String description;
}

final class UnknownActivityBlock extends ConversationTimelineBlock {
  const UnknownActivityBlock({
    required super.id,
    required super.turnId,
    required super.sourceItemIds,
    required super.isStreaming,
    required this.title,
    required this.detail,
    super.status,
  });

  final String title;
  final String detail;
}

final class TurnProcessBlock extends ConversationTimelineBlock {
  const TurnProcessBlock({required super.id, required super.turnId,
    required this.children, this.duration, required this.completed})
      : super(sourceItemIds: const [], isStreaming: !completed);
  final List<ConversationTimelineBlock> children;
  final Duration? duration;
  final bool completed;
}

class FileChangeSummary {
  const FileChangeSummary({required this.count, required this.details});
  final int count;
  final List<String> details;
}

final class ConversationTimelineProjector {
  const ConversationTimelineProjector();

  List<ConversationTimelineBlock> project(ConversationDetail detail, {bool mergeAssistantMessages = true}) {
    final items = _mergeItems(detail.messages);
    final attachedApprovals = <String, TimelineApproval>{};
    final attachableIds = <String>{
      for (final item in items)
        if (item.kind == 'command' || item.kind == 'tool') ...[
          item.id,
          if (item.itemId != null) item.itemId!,
        ],
    };
    for (final item in items) {
      if (item.kind != 'approval' ||
          item.relatedItemId == null ||
          !attachableIds.contains(item.relatedItemId)) {
        continue;
      }
      attachedApprovals[item.relatedItemId!] = _approval(item);
    }

    final blocks = <ConversationTimelineBlock>[];
    for (final item in items) {
      if (item.kind == 'approval' &&
          item.relatedItemId != null &&
          attachedApprovals.containsKey(item.relatedItemId)) {
        continue;
      }
      final approval = attachedApprovals[item.id] ??
          (item.itemId == null ? null : attachedApprovals[item.itemId!]);
      final block = _blockFor(item, approval);
      if (mergeAssistantMessages && block is AssistantMessageBlock &&
          blocks.isNotEmpty &&
          blocks.last is AssistantMessageBlock) {
        final previous = blocks.last as AssistantMessageBlock;
        if (previous.turnId == block.turnId) {
          blocks[blocks.length - 1] = previous.append(block);
          continue;
        }
      }
      blocks.add(block);
    }
    return List.unmodifiable(blocks);
  }

  /// Display grouping is separate from the lossless semantic projection.
  List<ConversationTimelineBlock> projectForDisplay(ConversationDetail detail) {
    final blocks = project(detail, mergeAssistantMessages: false).where((block) => block is! FileChangesBlock &&
      !(block is ReasoningBlock && (block.summary.trim().isEmpty ||
        const {'completed', 'running', 'pending'}.contains(block.summary.trim().toLowerCase())))).toList();
    final turns = {for (final turn in detail.turns) turn.id: turn};
    final active = detail.summary.activeTurn;
    if (active != null && !turns.containsKey(active.id)) turns[active.id] = active;
    final result = <ConversationTimelineBlock>[];
    var start = 0;
    while (start < blocks.length) {
      var end = start + 1;
      while (end < blocks.length && blocks[end].turnId == blocks[start].turnId &&
          blocks[end] is! UserMessageBlock) { end++; }
      final group = blocks.sublist(start, end);
      final turn = turns[group.first.turnId];
      final completed = turn?.status.isTerminal ??
        (!group.any((block) => block.isRunning) && detail.activeTurn?.id != group.first.turnId &&
          detail.effectiveStatus != ConversationStatus.running);
      final last = group.last is AssistantMessageBlock
        ? group.last as AssistantMessageBlock : null;
      final process = group.where((block) => block is! UserMessageBlock &&
        block is! ApprovalBlock && block != last).toList();
      result.addAll(group.whereType<UserMessageBlock>());
      if (process.isNotEmpty) {
        final duration = turn?.startedAt != null && turn?.completedAt != null
          ? turn!.completedAt!.difference(turn.startedAt!) : null;
        result.add(TurnProcessBlock(id: 'process-${group.first.id}',
          turnId: group.first.turnId, children: process,
          duration: duration != null && !duration.isNegative ? duration : null,
          completed: completed));
      }
      result.addAll(group.whereType<ApprovalBlock>());
      if (last != null) result.add(last);
      start = end;
    }
    return result;
  }

  FileChangeSummary fileChanges(ConversationDetail detail) {
    var count = 0;
    final details = <String>{};
    for (final item in _mergeItems(detail.messages).where((item) => item.kind == 'file-change')) {
      final text = _contentsOf(item).map((content) => content.displayText)
        .where((text) => text.trim().isNotEmpty).join('\n');
      final match = RegExp(r'^\s*(\d+) file change\(s\)\s*$', caseSensitive: false).firstMatch(text);
      count += match == null ? 1 : int.parse(match.group(1)!);
      if (text.trim().isNotEmpty && match == null &&
          !const {'completed', 'running', 'pending'}.contains(text.trim().toLowerCase())) {
        details.add(text);
      }
    }
    return FileChangeSummary(count: count, details: details.toList());
  }

  List<GatewayMessage> _mergeItems(List<GatewayMessage> messages) {
    final order = <String>[];
    final byKey = <String, GatewayMessage>{};
    for (final message in messages) {
      final key = '${message.turnId}\u0000${message.itemId ?? message.id}';
      final current = byKey[key];
      if (current == null) {
        order.add(key);
        byKey[key] = message;
        continue;
      }
      final contents = <GatewayMessageContent>[
        ..._contentsOf(current),
      ];
      for (final incoming in _contentsOf(message)) {
        final index = contents.indexWhere((content) => content.id == incoming.id);
        if (index == -1) {
          contents.add(incoming);
        } else if (message.isLiveOutput) {
          contents[index] = incoming;
        }
      }
      byKey[key] = GatewayMessage(
        id: current.id,
        itemId: current.itemId ?? message.itemId,
        turnId: current.turnId,
        role: current.role == MessageRole.system ? message.role : current.role,
        kind: current.kind == 'unknown' ? message.kind : current.kind,
        content: contents.map((content) => content.displayText).join('\n'),
        createdAt: current.createdAt,
        isStreaming: current.isStreaming || message.isStreaming,
        isLiveOutput: current.isLiveOutput || message.isLiveOutput,
        contentIds: contents.map((content) => content.id).toList(growable: false),
        contents: contents,
        title: current.title ?? message.title,
        status: message.status ?? current.status,
        approvalStatus: message.approvalStatus ?? current.approvalStatus,
        approvalDescription:
            message.approvalDescription ?? current.approvalDescription,
        relatedItemId: current.relatedItemId ?? message.relatedItemId,
        sequence: current.sequence ?? message.sequence,
        tool: message.tool ?? current.tool,
        meta: message.meta ?? current.meta,
      );
    }
    return [for (final key in order) byKey[key]!];
  }

  ConversationTimelineBlock _blockFor(
    GatewayMessage item,
    TimelineApproval? approval,
  ) {
    final common = (
      id: item.id,
      turnId: item.turnId,
      sourceItemIds: [item.id, if (item.itemId != null) item.itemId!],
      isStreaming: item.isStreaming,
      status: item.status,
    );
    final contents = _contentsOf(item);
    switch (item.kind) {
      case 'message':
        final text = _textFor(contents, const {'text'});
        if (item.role == MessageRole.user) {
          return UserMessageBlock(
            id: common.id,
            turnId: common.turnId,
            sourceItemIds: common.sourceItemIds,
            isStreaming: common.isStreaming,
            text: text,
            status: common.status,
          );
        }
        return AssistantMessageBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          text: text,
          status: common.status,
        );
      case 'reasoning':
        return ReasoningBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          summary: _textFor(
            contents,
            const {'reasoning-summary', 'text', 'activity-summary'},
          ),
          status: common.status,
        );
      case 'command':
        return CommandBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          title: item.title ?? '命令执行',
          command: _commandInputText(item.tool),
          output: _toolOutcomeText(item.tool).isNotEmpty
              ? _toolOutcomeText(item.tool)
              : _textFor(contents, const {'output'}),
          tool: item.tool,
          approval: approval,
          status: common.status,
        );
      case 'tool':
        return ToolBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          title: item.title ?? '工具调用',
          summary: _textFor(contents, const {'activity-summary', 'text'}),
          detail: _toolOutcomeText(item.tool).isNotEmpty
              ? _toolOutcomeText(item.tool)
              : _textFor(contents, const {'output'}),
          tool: item.tool,
          approval: approval,
          status: common.status,
        );
      case 'file-change':
        return FileChangesBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          title: item.title ?? '文件已更改',
          summary: _textFor(contents, const {
            'activity-summary',
            'text',
            'output',
          }),
          status: common.status,
        );
      case 'approval':
        final approval = _approval(item);
        return ApprovalBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          title: approval.title,
          description: approval.description ?? '',
          status: approval.status,
        );
      default:
        return UnknownActivityBlock(
          id: common.id,
          turnId: common.turnId,
          sourceItemIds: common.sourceItemIds,
          isStreaming: common.isStreaming,
          title: item.title ?? '活动',
          detail: _textFor(contents, const {
            'text',
            'reasoning-summary',
            'command',
            'output',
            'activity-summary',
          }),
          status: common.status,
        );
    }
  }

  TimelineApproval _approval(GatewayMessage item) => TimelineApproval(
        id: item.id,
        title: item.title ?? '需要审批',
        description: item.approvalDescription ??
            _textFor(_contentsOf(item), const {'text', 'activity-summary'}),
        status: item.approvalStatus ?? item.status,
      );

  List<GatewayMessageContent> _contentsOf(GatewayMessage item) {
    if (item.contents.isNotEmpty) return item.contents;
    final fallbackId = item.contentId ??
        (item.contentIds.isEmpty ? item.id : item.contentIds.first);
    return [
      GatewayMessageContent(
        id: fallbackId,
        kind: _legacyContentKind(item.kind),
        text: item.content,
      ),
    ];
  }

  String _textFor(
    List<GatewayMessageContent> contents,
    Set<String> acceptedKinds,
  ) =>
      contents
          .where((content) => acceptedKinds.contains(content.kind))
          .map((content) => content.displayText)
          .where((text) => text.trim().isNotEmpty)
          .join('\n\n');

  String _toolOutcomeText(GatewayToolInvocation? tool) {
    final outcome = tool?.outcome;
    if (outcome == null) return '';
    return outcome.content
        .map((content) {
          final truncation = content.truncation;
          if (truncation == null) return content.displayText;
          return '${content.displayText}\n'
              '[内容已截断：originalBytes=${truncation.originalBytes}, '
              'retainedBytes=${truncation.retainedBytes}, '
              'strategy=${truncation.strategy}]';
        })
        .where((value) => value.isNotEmpty)
        .join('\n\n');
  }

  String _commandInputText(GatewayToolInvocation? tool) {
    final input = tool?.input;
    if (input is! GatewayCommandToolInput) return '';
    final truncation = input.truncation;
    if (truncation == null) return input.command;
    return '${input.command}\n'
        '[内容已截断：originalBytes=${truncation.originalBytes}, '
        'retainedBytes=${truncation.retainedBytes}, '
        'strategy=${truncation.strategy}]';
  }

  String _legacyContentKind(String itemKind) => switch (itemKind) {
        'reasoning' => 'reasoning-summary',
        'command' => 'command',
        'tool' || 'file-change' || 'approval' => 'activity-summary',
        _ => 'text',
      };
}
