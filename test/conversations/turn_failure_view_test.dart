import 'package:codepet_remote/application/conversations/conversation_timeline.dart';
import 'package:codepet_remote/features/conversations/widgets/conversation_timeline_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 800.0]) {
    testWidgets('failure wraps at $width with large text and preserves composer focus', (tester) async {
      tester.view.reset();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final focus = FocusNode();
      final controller = TextEditingController(text: 'draft');
      Future<void> render(String reason) => tester.pumpWidget(MaterialApp(home: Scaffold(
        body: MediaQuery(data: MediaQueryData(size: Size(width, 900), textScaler: const TextScaler.linear(2)),
          child: Column(children: [
            Expanded(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16),
              child: ConversationTimelineBlockView(block: TurnFailureBlock(id: 'failure', turnId: 'turn',
                message: reason, retryable: true, errorCode: 'rate_limited', completedAt: DateTime(2026,11,8)))))),
            TextField(key: const Key('composer'), focusNode: focus, controller: controller),
          ])),
      )));
      await render('Too many requests');
      await tester.tap(find.byKey(const Key('composer')));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      await render('Free usage limit reached. ${'Long failure detail. ' * 30}');
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(controller.text, 'draft');
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.scrollUntilVisible(find.text('可稍后重新发送。'), 300, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      focus.dispose(); controller.dispose();
    });
  }
}
