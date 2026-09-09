import 'package:codepet_remote/features/conversations/widgets/conversation_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('running indicator advances frames and disappears when idle', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: ConversationIndicators(running: true, unread: true),
    )));
    final indicator = find.byType(CircularProgressIndicator);
    expect(tester.getSize(indicator), const Size(16, 16));
    final paint = find.descendant(of: indicator, matching: find.byType(CustomPaint));
    final before = tester.widget<CustomPaint>(paint).painter!;
    await tester.pump(const Duration(milliseconds: 200));
    final after = tester.widget<CustomPaint>(paint).painter!;
    expect(after.shouldRepaint(before), isTrue);
    expect(find.byTooltip('运行中'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: ConversationIndicators(running: false, unread: true),
    )));
    expect(indicator, findsNothing);
    expect(find.byWidgetPredicate((widget) =>
        widget is Semantics && widget.properties.label == '未读'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
