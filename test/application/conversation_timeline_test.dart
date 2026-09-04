import 'package:codepet_remote/application/conversations/conversation_timeline.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const projector = ConversationTimelineProjector();

  test('keeps command and output contents in one semantic block', () {
    final detail = ConversationDetail(
      summary: _summary,
      committedMessages: [
        _message(
          id: 'command-item',
          kind: 'command',
          role: MessageRole.system,
          tool: const GatewayToolInvocation(
            callId: 'command-item',
            name: 'shell',
            category: 'command',
            originKind: 'builtin',
            input: GatewayCommandToolInput(command: 'git status --short'),
            outcome: GatewayToolSuccess(
              content: [
                GatewayMessageContent(
                  id: 'command-item:output',
                  kind: 'output',
                  text: ' M lib/main.dart',
                ),
              ],
            ),
          ),
        ),
      ],
    );

    final block = projector.project(detail).single as CommandBlock;
    expect(block.command, 'git status --short');
    expect(block.output, ' M lib/main.dart');
  });

  test('attaches related approval to its command', () {
    final detail = ConversationDetail(
      summary: _summary,
      committedMessages: [
        _message(
          id: 'routed-command',
          itemId: 'command',
          kind: 'command',
          role: MessageRole.system,
          tool: const GatewayToolInvocation(
            callId: 'command',
            name: 'shell',
            category: 'command',
            originKind: 'builtin',
            input: GatewayCommandToolInput(command: 'flutter build apk'),
          ),
        ),
        GatewayMessage(
          id: 'approval',
          turnId: 'turn',
          role: MessageRole.system,
          kind: 'approval',
          content: 'Allow build?',
          createdAt: _epoch,
          isStreaming: false,
          title: '批准命令',
          approvalDescription: 'Allow build?',
          approvalStatus: 'approved',
          relatedItemId: 'routed-command',
        ),
      ],
    );

    final blocks = projector.project(detail);
    expect(blocks, hasLength(1));
    final command = blocks.single as CommandBlock;
    expect(command.approval?.title, '批准命令');
    expect(command.approval?.status, 'approved');
  });

  test('merges adjacent assistant text within the same turn', () {
    final detail = ConversationDetail(
      summary: _summary,
      committedMessages: [
        _message(id: 'first', content: '第一段'),
        _message(id: 'second', content: '第二段'),
      ],
    );

    final block = projector.project(detail).single as AssistantMessageBlock;
    expect(block.text, '第一段\n\n第二段');
    expect(block.sourceItemIds, containsAll(['first', 'second']));
  });

  test('projects live command and output deltas onto the same block', () {
    var detail = ConversationDetail(
      summary: _summary,
      committedMessages: [
        _message(
          id: 'live-command',
          itemId: 'live-command',
          kind: 'command',
          role: MessageRole.system,
          tool: const GatewayToolInvocation(
            callId: 'live-command',
            name: 'shell',
            category: 'command',
            originKind: 'builtin',
            input: GatewayCommandToolInput(command: 'pwd'),
          ),
        ),
      ],
    );
    detail = detail.apply(
      const TurnOutputDeltaEvent(
        eventCursor: 'output-delta',
        providerId: 'provider',
        conversationId: 'conversation',
        turnId: 'turn',
        itemId: 'live-command',
        contentId: 'live-command:output',
        kind: 'output',
        delta: '/workspace',
      ),
    );

    expect(detail.liveOutputMessages, hasLength(1));
    final block = projector.project(detail).single as CommandBlock;
    expect(block.command, 'pwd');
    expect(block.output, '/workspace');
    expect(block.isStreaming, isTrue);
  });
}

GatewayMessage _message({
  required String id,
  String? itemId,
  String kind = 'message',
  MessageRole role = MessageRole.assistant,
  String content = '',
  List<GatewayMessageContent> contents = const [],
  GatewayToolInvocation? tool,
}) =>
    GatewayMessage(
      id: id,
      itemId: itemId,
      turnId: 'turn',
      role: role,
      kind: kind,
      content: content,
      contents: contents,
      contentIds: contents.map((value) => value.id).toList(growable: false),
      createdAt: _epoch,
      isStreaming: false,
      tool: tool,
    );

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

final _summary = ConversationSummary(
  id: 'conversation',
  providerId: 'provider',
  title: 'Conversation',
  status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.workspaceWrite,
  createdAt: _epoch,
  updatedAt: _epoch,
);
