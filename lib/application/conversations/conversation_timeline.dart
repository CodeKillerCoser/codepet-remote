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

final class ConversationTimelineProjector {
  const ConversationTimelineProjector();

  List<ConversationTimelineBlock> project(ConversationDetail detail) {
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
      if (block is AssistantMessageBlock &&
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
        content: contents.map((content) => content.text).join('\n'),
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
          command: item.tool?.command ?? _textFor(contents, const {'command'}),
          output: _toolResultText(item.tool) ??
              _textFor(contents, const {'output', 'activity-summary'}),
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
          detail: _textFor(contents, const {'command', 'output'}),
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
          .map((content) => content.text)
          .where((text) => text.trim().isNotEmpty)
          .join('\n\n');

  String? _toolResultText(GatewayToolInvocation? tool) {
    if (tool == null) return null;
    final text = tool.resultContent
        .map((content) => content.text ?? content.uri ?? '')
        .where((value) => value.isNotEmpty)
        .join('\n\n');
    return text.isEmpty ? null : text;
  }

  String _legacyContentKind(String itemKind) => switch (itemKind) {
        'reasoning' => 'reasoning-summary',
        'command' => 'command',
        'tool' || 'file-change' || 'approval' => 'activity-summary',
        _ => 'text',
      };
}
