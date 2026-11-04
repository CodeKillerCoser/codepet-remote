import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows isolated multi-device projections', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    expect(find.text('CodePet Remote'), findsOneWidget);
    expect(find.byKey(const Key('home-device-menu')), findsOneWidget);
    expect(find.byKey(const Key('device-demo-studio')), findsNothing);
    await tester.tap(find.byKey(const Key('home-device-menu')));
    await _pumpDemoFrames(tester);
    expect(find.byKey(const Key('device-demo-studio')), findsOneWidget);
    expect(find.byKey(const Key('device-demo-laptop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-demo-laptop')));
    await _pumpDemoFrames(tester);
    expect(find.text('Gateway 协议契约核对'), findsNothing);
    final harnessTop = tester.getTopLeft(
      find.byKey(const Key('connected-providers')),
    ).dy;
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
    await tester.tap(find.byKey(const Key('home-device-menu')));
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

  testWidgets('overflow exposes connection and settings entries', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await _pumpDemoFrames(tester);
    expect(find.text('连接设备'), findsOneWidget);
    expect(find.text('App 设置'), findsOneWidget);
    await tester.tap(find.text('连接设备'));
    await _pumpDemoFrames(tester);
    expect(find.text('配对 CodePet Host'), findsOneWidget);
    expect(find.byKey(const Key('manual-add-device')), findsOneWidget);
    expect(find.byKey(const Key('manual-qr-scanner')), findsNothing);
  });

  testWidgets('offers QR and passcode methods behind manual add', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await _pumpDemoFrames(tester);
    await tester.tap(find.text('连接设备'));
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
      (tester) async {
    await tester.pumpWidget(CodePetRemoteApp(
      includeDemoDevices: true,
      logExporter: () async => '/local/codepet-logs.zip',
    ));
    await _pumpDemoFrames(tester);
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await _pumpDemoFrames(tester);
    await tester.tap(find.text('App 设置'));
    await _pumpDemoFrames(tester);

    await tester.tap(find.byKey(const Key('export-logs')));
    await _pumpDemoFrames(tester);

    expect(find.text('/local/codepet-logs.zip'), findsOneWidget);
    expect(find.byKey(const Key('share-logs')), findsOneWidget);
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
