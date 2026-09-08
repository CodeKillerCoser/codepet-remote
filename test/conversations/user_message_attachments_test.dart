import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/application/conversations/conversation_timeline.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/features/conversations/widgets/conversation_timeline_view.dart';
import 'package:codepet_remote/gateway/generated_gateway_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Gateway file blocks remain separate and render inside the user bubble',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const fileName =
          'codex-clipboard-c3355ca9-26e9-4ed9-b33f-3bae5d823dff.jpg';
      final message = const GeneratedGatewayMapper().message(
        sdk.ConversationItem.fromJson({
          'resource': _resource('user'),
          'turn': _resource('turn'),
          'conversation': _resource('conversation'),
          'kind': 'message',
          'role': 'user',
          'status': 'completed',
          'contents': [
            {
              'contentId': 'file',
              'kind': 'resource-link',
              'name': fileName,
              'uri': 'file:///C:/Users/Test/Temp/$fileName',
            },
            {'contentId': 'text', 'kind': 'text', 'text': '连接失败怎么是空的了？原来的界面呢'},
            {
              'contentId': 'image',
              'kind': 'image',
              'uri': 'data:image/png;base64,example',
            },
          ],
        }),
        0,
      );
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final detail = ConversationDetail(
        summary: ConversationSummary(
          id: 'conversation',
          providerId: 'provider',
          title: 'Test',
          status: ConversationStatus.idle,
          permissionLevel: PermissionLevel.readOnly,
          createdAt: epoch,
          updatedAt: epoch,
        ),
        committedMessages: [message],
      );
      final block =
          const ConversationTimelineProjector().project(detail).single
              as UserMessageBlock;
      expect(block.text, '连接失败怎么是空的了？原来的界面呢');
      expect(block.attachments.map((attachment) => attachment.kind), [
        'resource-link',
        'image',
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConversationTimelineBlockView(block: block)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.text(fileName), findsOneWidget);
      expect(find.text('图片附件'), findsOneWidget);
      expect(find.text(block.text, findRichText: true), findsOneWidget);
      expect(find.textContaining('C:/Users/'), findsNothing);
      expect(find.textContaining('base64'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('attachment-only user messages remain visible', (tester) async {
    const block = UserMessageBlock(
      id: 'file-only',
      turnId: 'turn',
      sourceItemIds: ['file-only'],
      isStreaming: false,
      text: '',
      attachments: [
        GatewayMessageContent(
          id: 'doc',
          kind: 'resource-link',
          name: '需求说明.pdf',
          uri: 'file:///tmp/spec.pdf',
        ),
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConversationTimelineBlockView(block: block)),
      ),
    );
    expect(find.text('需求说明.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Map<String, String> _resource(String id) => {
  'providerId': 'provider',
  'nativeResourceId': id,
};
