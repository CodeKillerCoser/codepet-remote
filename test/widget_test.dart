import 'dart:async';

import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows isolated multi-device projections', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    expect(find.text('演示工作室 Mac'), findsOneWidget);
    expect(find.byKey(const Key('home-navigation-menu')), findsOneWidget);
    expect(find.byKey(const Key('device-demo-studio')), findsNothing);
    await tester.tap(find.byKey(const Key('home-navigation-menu')));
    await _pumpDemoFrames(tester);
    expect(find.byKey(const Key('device-demo-studio')), findsOneWidget);
    expect(find.byKey(const Key('device-demo-laptop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-demo-laptop')));
    await _pumpDemoFrames(tester);
    expect(find.text('Gateway 协议契约核对'), findsNothing);
    final harnessTop = tester.getTopLeft(
      find.byKey(const Key('connected-providers'))).dy;
    await tester.scrollUntilVisible(
      find.text('无项目临时会话'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('remote-home')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('无项目临时会话'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('connected-providers'))).dy,
      harnessTop,
    );
    final homeScroll = find.descendant(
      of: find.byKey(const Key('remote-home')),
      matching: find.byType(Scrollable),
    ).first;
    await tester.drag(homeScroll, const Offset(0, 1000));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-navigation-menu')));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('device-demo-studio')));
    await _pumpDemoFrames(tester);
    await tester.scrollUntilVisible(
      find.text('Gateway 协议契约核对'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('remote-home')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('Gateway 协议契约核对'), findsOneWidget);
    expect(find.text('无项目临时会话'), findsNothing);
  });

  testWidgets('edge swipe opens drawer and settings stays anchored', (
    tester,
  ) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    await tester.dragFrom(const Offset(1, 250), const Offset(320, 0));
    await _pumpDemoFrames(tester);
    expect(
      find.byKey(const Key('drawer-settings')).hitTestable(),
      findsOneWidget,
    );
    final settingsPosition = tester.getTopLeft(
      find.byKey(const Key('drawer-settings')),
    );
    await tester.drag(
      find.byKey(const Key('device-demo-studio')),
      const Offset(0, -150),
    );
    await _pumpDemoFrames(tester);
    expect(
      tester.getTopLeft(find.byKey(const Key('drawer-settings'))),
      settingsPosition,
    );
    await tester.tapAt(const Offset(700, 300));
    await _pumpDemoFrames(tester);
    expect(
      find.byKey(const Key('drawer-settings')).hitTestable(),
      findsNothing,
    );
  });

  testWidgets('drawer exposes connection and settings entries', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-navigation-menu')));
    await _pumpDemoFrames(tester);
    expect(find.text('添加设备'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.text('添加设备'));
    await _pumpDemoFrames(tester);
    expect(find.text('配对 CodePet Host'), findsOneWidget);
    expect(find.byKey(const Key('manual-add-device')), findsOneWidget);
    expect(find.byKey(const Key('manual-qr-scanner')), findsNothing);
  });

  for (final entry in ['drawer-settings', 'drawer-add-device', 'drawer-manage-devices']) {
    testWidgets('returning from $entry preserves drawer navigation stack', (tester) async {
      await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
      await _pumpDemoFrames(tester);
      await tester.tap(find.byKey(const Key('home-navigation-menu')));
      await _pumpDemoFrames(tester);
      await tester.tap(find.byKey(Key(entry)));
      await _pumpDemoFrames(tester);
      expect(find.byKey(const Key('drawer-settings')).hitTestable(), findsNothing);

      await tester.binding.handlePopRoute();
      await _pumpDemoFrames(tester);
      expect(find.byKey(const Key('drawer-settings')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('drawer-manage-devices')).hitTestable(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _pumpDemoFrames(tester);
      expect(find.byKey(const Key('drawer-settings')).hitTestable(), findsNothing);
      expect(find.byKey(const Key('home-navigation-menu')).hitTestable(), findsOneWidget);
    });
  }

  testWidgets('offers QR and passcode methods behind manual add', (tester,
  ) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-navigation-menu')));
    await _pumpDemoFrames(tester);
    await tester.tap(find.text('添加设备'));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('manual-add-device')));
    await _pumpDemoFrames(tester);
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.text('粘贴二维码内容'), findsOneWidget);
    expect(find.text('填写配对口令'), findsOneWidget);
    await tester.tap(find.byKey(const Key('manual-paste-qr')));
    await _pumpDemoFrames(tester);
    expect(find.byKey(const Key('qr-json-field')), findsOneWidget);
    expect(find.byKey(const Key('pair-json-button')), findsOneWidget);
  });

  testWidgets('settings exports diagnostics and shows the archive path',
      (tester,
  ) async {
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final shareResult = Completer<String>();
    final shareCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      shareChannel,
      (call) {
        shareCalls.add(call);
        return shareResult.future;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        shareChannel,
        null,
      );
    });
    await tester.pumpWidget(CodePetRemoteApp(
      includeDemoDevices: true,
      logExporter: () async => '/local/codepet-logs.zip',
    ),
    );
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-navigation-menu')));
    await _pumpDemoFrames(tester);
    await tester.tap(find.text('设置'));
    await _pumpDemoFrames(tester);

    await tester.tap(find.byKey(const Key('export-logs')));
    await _pumpDemoFrames(tester);

    expect(find.text('/local/codepet-logs.zip'), findsOneWidget);
    expect(shareCalls, hasLength(1));
    expect(shareCalls.single.method, 'share');
    expect(shareCalls.single.arguments['paths'], ['/local/codepet-logs.zip']);
    expect(shareCalls.single.arguments['mimeTypes'], ['application/zip']);
    expect(find.byKey(const Key('share-logs')), findsNothing);

    shareResult.complete('dev.fluttercommunity.plus/share/dismissed');
    await _pumpDemoFrames(tester);
    expect(find.byKey(const Key('share-logs')).hitTestable(), findsOneWidget);
  });
}

// Demo conversations include a persistent running indicator, so the app never
// settles. Advance frames for the demo connection/list delays and route/menu
// transitions, then let each test assert the resulting UI state.
Future<void> _pumpDemoFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
