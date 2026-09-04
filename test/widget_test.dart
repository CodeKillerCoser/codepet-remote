import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows isolated multi-device projections', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await tester.pumpAndSettle();
    expect(find.text('CodePet Remote'), findsOneWidget);
    expect(find.byKey(const Key('device-demo-studio')), findsOneWidget);
    expect(find.byKey(const Key('device-demo-laptop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-demo-laptop')));
    await tester.pumpAndSettle();
    expect(find.text('Gateway 协议契约核对'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('无项目临时会话'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('remote-home')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('无项目临时会话'), findsOneWidget);
    final homeScroll = find.descendant(
      of: find.byKey(const Key('remote-home')),
      matching: find.byType(Scrollable),
    ).first;
    await tester.drag(homeScroll, const Offset(0, 1000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-demo-studio')));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await tester.pumpAndSettle();
    expect(find.text('连接设备'), findsOneWidget);
    expect(find.text('App 设置'), findsOneWidget);
    await tester.tap(find.text('连接设备'));
    await tester.pumpAndSettle();
    expect(find.text('配对 CodePet Host'), findsOneWidget);
    expect(find.byKey(const Key('manual-add-device')), findsOneWidget);
    expect(find.byKey(const Key('manual-qr-scanner')), findsNothing);
  });

  testWidgets('offers QR and passcode methods behind manual add', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-add-device')));
    await tester.pumpAndSettle();
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.text('粘贴二维码内容'), findsOneWidget);
    expect(find.text('填写配对口令'), findsOneWidget);
    await tester.tap(find.byKey(const Key('manual-paste-qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr-json-field')), findsOneWidget);
    expect(find.byKey(const Key('pair-json-button')), findsOneWidget);
  });

  testWidgets('settings exports diagnostics and shows the archive path',
      (tester) async {
    await tester.pumpWidget(CodePetRemoteApp(
      includeDemoDevices: true,
      logExporter: () async => '/local/codepet-logs.zip',
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('App 设置'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();

    expect(find.text('/local/codepet-logs.zip'), findsOneWidget);
    expect(find.byKey(const Key('share-logs')), findsOneWidget);
  });
}
