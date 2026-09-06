import 'package:codepet_remote/application/conversations/conversation_timeline.dart';
import 'package:codepet_remote/features/common/app_toast.dart';
import 'package:codepet_remote/features/conversations/widgets/conversation_timeline_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final calls = <MethodCall>[];
  var launchSucceeds = true;
  var throwsPlatformError = false;

  setUp(() {
    calls.clear();
    launchSucceeds = true;
    throwsPlatformError = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (throwsPlatformError) throw PlatformException(code: 'unavailable');
      return launchSucceeds;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final userMessage in [true, false]) {
    testWidgets('opens Markdown and bare links in userMessage=$userMessage',
        (tester) async {
      await _pumpMessage(tester,
        '[文档](https://example.com/docs?q=hello#section)\n\nhttps://example.com/plain',
        userMessage: userMessage,
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('文档', findRichText: true));
      await tester.pump();
      expect(calls.single.method, 'launch');
      expect(calls.single.arguments['url'], 'https://example.com/docs?q=hello#section');
      expect(calls.single.arguments['useWebView'], isFalse);
      expect(calls.single.arguments['useSafariVC'], isFalse);
      await tester.tap(find.text('https://example.com/plain', findRichText: true));
      await tester.pump();
      expect(calls.last.arguments['url'], 'https://example.com/plain');
      expect(calls, hasLength(2));
    });
  }

  for (final platformThrows in [false, true]) {
    testWidgets('shows launch failure when platformThrows=$platformThrows',
        (tester) async {
      launchSucceeds = false;
      throwsPlatformError = platformThrows;
      await _pumpMessage(tester, '[文档](https://example.com)');
      await tester.tap(find.text('文档', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('无法打开链接，请复制链接后重试', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('does not send host file paths to the phone launcher', (tester) async {
    await _pumpMessage(tester, '[源码](/workspace/app.dart)');
    await tester.tap(find.text('源码', findRichText: true));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('此链接无法在当前设备打开', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

Future<void> _pumpMessage(WidgetTester tester, String text, {
  bool userMessage = false,
}) async {
  final ConversationTimelineBlock block = userMessage
      ? UserMessageBlock(id: 'message', turnId: 'turn', sourceItemIds: const ['message'],
          isStreaming: false, text: text)
      : AssistantMessageBlock(id: 'message', turnId: 'turn', sourceItemIds: const ['message'],
          isStreaming: false, text: text);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => AppToastHost(child: child!),
    home: Scaffold(body: ConversationTimelineBlockView(block: block)),
  ));
  await tester.pumpAndSettle();
}
