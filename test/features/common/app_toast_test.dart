import 'package:codepet_remote/features/common/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows rich icon toasts in a centered top stack and hides them',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppToastHost(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  AppToast.show(
                    type: AppToastType.success,
                    duration: const Duration(seconds: 3),
                    content: const TextSpan(
                      children: [
                        TextSpan(
                          text: '第一条',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: '成功消息'),
                      ],
                    ),
                  );
                  AppToast.show(
                    type: AppToastType.warning,
                    duration: const Duration(seconds: 3),
                    content: const TextSpan(text: '第二条警告消息'),
                  );
                },
                child: const Text('显示'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('app-toast-content')), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    final toastStack = find.byType(Stack).last;
    expect(toastStack, findsOneWidget);
    expect(tester.getCenter(toastStack).dx, moreOrLessEquals(400));
    expect(tester.getTopLeft(toastStack).dy, lessThan(60));

    final cards = find.byKey(const Key('app-toast-card'));
    expect(tester.getSize(cards.first).width, lessThanOrEqualTo(300));
    expect(tester.getSize(cards.first).height, lessThan(60));
    final verticalOffset =
        (tester.getTopLeft(cards.first).dy - tester.getTopLeft(cards.last).dy)
            .abs();
    expect(verticalOffset, moreOrLessEquals(10, epsilon: 1));

    final richText = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText() == '第一条成功消息',
      ),
    );
    final children = (richText.textSpan! as TextSpan).children!;
    expect(children.first.style!.fontWeight, FontWeight.w600);

    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('app-toast-content')), findsNothing);
  });
}
