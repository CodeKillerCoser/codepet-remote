import 'package:codepet_remote/core/domain/signaling_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/app/channel_preferences.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/webrtc/cloud_signaling.dart';
import 'package:codepet_remote/features/settings/signaling_service_settings.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('normalizes IP, domain, IPv6 and explicit HTTPS ports', () {
    for (final entry in {
      ' 172.96.254.12 ': 'https://172.96.254.12:8443',
      'signal.example.com': 'https://signal.example.com:8443',
      'signal.example.com:443': 'https://signal.example.com',
      'signal.example.com:9443': 'https://signal.example.com:9443',
      'https://signal.example.com/': 'https://signal.example.com',
      '2001:db8::1': 'https://[2001:db8::1]:8443',
      '[2001:db8::1]:9443': 'https://[2001:db8::1]:9443',
    }.entries) {
      expect(normalizeSignalingService(entry.key), entry.value);
    }
    expect(normalizeSignalingService(' '), isNull);
  });

  test('rejects insecure or credential-bearing addresses', () {
    for (final value in [
      'http://example.com',
      'https://user:pass@example.com',
      'example.com/api',
      'example.com?token=secret',
      'example.com#fragment',
      'host name',
      'host:0',
      'host:65536',
      'https://',
      r'example.com\evil',
    ]) {
      expect(
        () => normalizeSignalingService(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('preferences persist the normalized service and preserve it on invalid input', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await ChannelPreferences.loadSignalingService(), isNull);
    await ChannelPreferences.saveSignalingService('172.96.254.12');
    expect(
      await ChannelPreferences.loadSignalingService(),
      'https://172.96.254.12:8443',
    );
    await expectLater(
      ChannelPreferences.saveSignalingService('http://insecure.example'),
      throwsFormatException,
    );
    expect(
      await ChannelPreferences.loadSignalingService(),
      'https://172.96.254.12:8443',
    );
    await ChannelPreferences.saveSignalingService(null);
    expect(await ChannelPreferences.loadSignalingService(), isNull);
  });

  test('service selection never forwards an existing authorization to another origin', () {
    final state = {
      'serviceUrl': 'https://signal.example.com:443/',
      'token': 'private',
    };
    validateSignalingServiceBinding(state, null);
    validateSignalingServiceBinding(state, 'https://signal.example.com');
    expect(
      () => validateSignalingServiceBinding(state, 'other.example.com'),
      throwsA(isA<GatewayConnectionException>()),
    );
    expect(state['serviceUrl'], 'https://signal.example.com:443/');
  });

  testWidgets(
    'small-screen service input validates before saving and keeps retry visible',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <String?>[];
      Object? failure;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                SignalingServiceSettings(
                  onSave: (value) async {
                    if (failure != null) throw failure;
                    saved.add(value);
                  },
                ),
              ],
            ),
          ),
        ),
      );
      final input = find.byKey(const Key('signaling-service-address'));
      final save = find.byKey(const Key('save-signaling-service'));
      await tester.enterText(input, 'http://insecure.example');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.textContaining('请输入 IP'), findsOneWidget);
      await tester.enterText(input, '172.96.254.12');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved, ['https://172.96.254.12:8443']);
      expect(find.text('设备已登记，可开始配对'), findsOneWidget);
      expect(save.hitTestable(), findsOneWidget);
      failure = const SignalingRegistrationException('信令服务尚未启用自动登记，请更新服务端');
      await tester.enterText(input, 'new.example.com');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('信令服务尚未启用自动登记，请更新服务端'), findsOneWidget);
      expect(saved, hasLength(1));
      expect(save.hitTestable(), findsOneWidget);
      failure = StateError('disk');
      await tester.enterText(input, 'new.example.com');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(saved, hasLength(1));
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
