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
    expect(find.text('实现 Remote 会话流'), findsOneWidget);
    expect(find.text('检查 Android 构建'), findsNothing);
    await tester.tap(find.byKey(const Key('device-demo-laptop')));
    await tester.pumpAndSettle();
    expect(find.text('实现 Remote 会话流'), findsNothing);
    expect(find.text('检查 Android 构建'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('无项目临时会话'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('remote-home')),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('无项目临时会话'), findsOneWidget);
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
    expect(find.text('扫描 Host 显示的 LAN 配对二维码'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('开发诊断：粘贴 QR JSON'), 300);
    expect(find.text('开发诊断：粘贴 QR JSON'), findsOneWidget);
  });

  testWidgets('offers pinned QR JSON diagnostics without a raw token field', (tester) async {
    await tester.pumpWidget(const CodePetRemoteApp(includeDemoDevices: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-overflow-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接设备'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('开发诊断：粘贴 QR JSON'), 300);
    await tester.tap(find.text('开发诊断：粘贴 QR JSON'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr-json-field')), findsOneWidget);
    expect(find.byKey(const Key('pair-json-button')), findsOneWidget);
    expect(find.byKey(const Key('pairing-token-field')), findsNothing);
  });
}
