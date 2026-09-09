import 'package:codepet_remote/app/channel_preferences.dart';
import 'package:codepet_remote/features/settings/app_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('channel choice persists and applies only to a restarted app', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    expect(await ChannelPreferences.loadWebRtcEnabled(), isFalse);
    Future<void> openSettings(bool active) async {
      final saved = await ChannelPreferences.loadWebRtcEnabled();
      await tester.pumpWidget(
        MaterialApp(
          home: AppSettingsScreen(
            key: UniqueKey(),
            sessions: const [],
            onForgetDevice: (_) async {},
            exportLogs: () async => '',
            activeWebRtcEnabled: active,
            webRtcEnabled: saved,
            onWebRtcChanged: ChannelPreferences.saveWebRtcEnabled,
          ),
        ),
      );
    }

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openSettings(false);
    await tester.tap(find.byKey(const Key('webrtc-switch')));
    await tester.pumpAndSettle();
    expect(await ChannelPreferences.loadWebRtcEnabled(), isTrue);
    expect(find.text('当前通道：LAN / WSS'), findsOneWidget);
    expect(find.text('设置已保存，重启 App 后生效'), findsOneWidget);
    await openSettings(false);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('webrtc-switch')))
          .value,
      isTrue,
    );
    await openSettings(await ChannelPreferences.loadWebRtcEnabled());
    expect(find.text('当前通道：WebRTC'), findsOneWidget);
    expect(find.text('设置已保存，重启 App 后生效'), findsNothing);
    await tester.tap(find.byKey(const Key('webrtc-switch')));
    await tester.pumpAndSettle();
    expect(await ChannelPreferences.loadWebRtcEnabled(), isFalse);
    expect(find.text('当前通道：WebRTC'), findsOneWidget);
    await openSettings(await ChannelPreferences.loadWebRtcEnabled());
    expect(find.text('当前通道：LAN / WSS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save preserves the selected channel', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppSettingsScreen(
          sessions: const [],
          onForgetDevice: (_) async {},
          exportLogs: () async => '',
          onWebRtcChanged: (_) async => throw StateError('disk failed'),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('webrtc-switch')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('webrtc-switch')))
          .value,
      isFalse,
    );
    expect(find.text('保存失败，请重试'), findsOneWidget);
  });
}
