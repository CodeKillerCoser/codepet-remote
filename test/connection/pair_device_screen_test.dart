import 'package:codepet_remote/application/pairing/pair_device.dart';
import 'package:codepet_remote/application/ports/pairing_gateway.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/features/connection/pair_device_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shows connected devices separately and refreshes discovered devices',
    (tester) async {
      final session = DeviceSession(
        device: const PairedDevice(
          deviceId: 'paired-host',
          displayName: 'Studio Mac',
          descriptor: DeviceDescriptor(
            deviceName: 'Studio Mac',
            operatingSystem: 'macOS',
            systemVersion: '15.6',
          ),
          connectionKind: DeviceConnectionKind.pairedGateway,
        ),
        clientFactory: () => throw StateError('not used'),
      )
        ..connectionState = DeviceConnectionState.online
        ..handshake = const GatewayHandshake(
          protocolVersion: 1,
          eventCursor: '1',
          deviceDescriptor: DeviceDescriptor(
            deviceName: 'Studio Mac',
            operatingSystem: 'macOS',
            systemVersion: '15.6',
          ),
          providers: [
            GatewayProvider(
              id: 'codex',
              displayName: 'Codex',
              status: ProviderStatus.ready,
              runtimeVersion: '0.152.1',
              executablePath: '/Applications/ChatGPT.app/Contents/Resources/codex',
              authenticationStatus: 'signed-in',
              authenticationDisplayText: 'Signed in · ChatGPT Pro',
              usageDisplayText: '7d 28% remaining',
              usageDetails: [
                {
                  'namespace': 'openai.codex.rate-limits',
                  'schemaVersion': '1',
                  'data': {'remainingPercent': 28},
                },
              ],
              capabilities: GatewayCapabilities(
                revision: 'codex-1',
                methods: ['project.list', 'conversation.list'],
              ),
            ),
          ],
        );
      var refreshCalls = 0;

      await tester.pumpWidget(MaterialApp(
        home: PairDeviceScreen(
          pairingService: _Pairer(),
          connectedSessions: [session],
          initialCandidates: const [
            PairingCandidate(
              deviceId: 'paired-host',
              displayName: 'Studio Mac',
              host: '192.168.1.10',
              port: 49152,
              tlsFingerprint:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              hostInitiated: false,
            ),
            PairingCandidate(
              deviceId: 'new-host',
              displayName: 'Office Mac',
              host: '192.168.1.11',
              port: 49153,
              tlsFingerprint:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              hostInitiated: false,
            ),
          ],
          onRefreshDiscovery: () async {
            refreshCalls++;
          },
          onPaired: (_) async {},
        ),
      ));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('connected-devices-title')),
        400,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.byKey(const Key('connected-devices-title')), findsOneWidget);
      expect(find.text('名称'), findsOneWidget);
      expect(find.text('系统'), findsOneWidget);
      expect(find.text('在线状态'), findsOneWidget);
      expect(find.text('Studio Mac'), findsOneWidget);
      expect(find.text('macOS 15.6'), findsOneWidget);
      expect(find.text('在线'), findsOneWidget);
      await tester.tap(find.byKey(const Key('connected-device-paired-host')));
      await tester.pumpAndSettle();
      expect(find.text('设备详情'), findsOneWidget);
      expect(find.text('0.152.1'), findsOneWidget);
      expect(
        find.text('/Applications/ChatGPT.app/Contents/Resources/codex'),
        findsOneWidget,
      );
      expect(find.text('Signed in · ChatGPT Pro'), findsOneWidget);
      expect(find.text('7d 28% remaining'), findsOneWidget);
      expect(find.byKey(const Key('device-reconnect')), findsOneWidget);
      expect(find.byKey(const Key('device-disconnect')), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('discovered-devices-title')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('discovered-devices-title')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Office Mac'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Office Mac'), findsOneWidget);

      final refresh = find.byKey(const Key('refresh-discovered-devices'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pump();

      expect(refreshCalls, 1);
      expect(find.text('暂未发现可配对设备'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('keeps camera closed until manual QR scanning is selected', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: PairDeviceScreen(
        pairingService: _Pairer(),
        onPaired: (_) async {},
      ),
    ));

    expect(find.byKey(const Key('manual-qr-scanner')), findsNothing);
    expect(find.byKey(const Key('manual-add-device')), findsOneWidget);

    await tester.tap(find.byKey(const Key('manual-add-device')));
    await tester.pumpAndSettle();

    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.text('粘贴二维码内容'), findsOneWidget);
    expect(find.text('填写配对口令'), findsOneWidget);
    expect(find.byKey(const Key('manual-qr-scanner')), findsNothing);

    await tester.tap(find.byKey(const Key('manual-paste-qr')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qr-json-field')), findsOneWidget);
    expect(find.byKey(const Key('pair-json-button')), findsOneWidget);
  });

  testWidgets('shows a discovered Host again when its saved session failed', (
    tester,
  ) async {
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'paired-host',
        displayName: 'Studio Mac',
        connectionKind: DeviceConnectionKind.pairedGateway,
      ),
      clientFactory: () => throw StateError('not used'),
    )..connectionState = DeviceConnectionState.failed;

    await tester.pumpWidget(MaterialApp(
      home: PairDeviceScreen(
        pairingService: _Pairer(),
        connectedSessions: [session],
        initialCandidates: const [
          PairingCandidate(
            deviceId: 'paired-host',
            displayName: 'Studio Mac',
            host: '10.0.2.2',
            port: 47622,
            tlsFingerprint:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            hostInitiated: false,
          ),
        ],
        onPaired: (_) async {},
      ),
    ));

    await tester.scrollUntilVisible(
      find.text('重新配对'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Studio Mac'), findsNWidgets(2));
    expect(find.text('重新配对'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('manual passcode starts a discovered-host request before entry', (
    tester,
  ) async {
    const host = PairingCandidate(
      deviceId: 'office-host',
      displayName: 'Office Mac',
      host: '192.168.1.11',
      port: 49153,
      tlsFingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      hostInitiated: false,
    );
    final discovery = _DiscoveryPairer(host);
    await tester.pumpWidget(MaterialApp(
      home: PairDeviceScreen(
        pairingService: _Pairer(),
        discoveryService: discovery,
        initialCandidates: const [host],
        onPaired: (_) async {},
      ),
    ));

    await tester.tap(find.byKey(const Key('manual-add-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-enter-code')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('manual-passcode-host-office-host')),
    );
    await tester.pumpAndSettle();

    expect(discovery.requestCalls, 1);
    expect(find.byKey(const Key('pairing-code-field')), findsOneWidget);
    expect(find.text('请输入 Office Mac 上显示的 6 位数字。'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('confirm-pairing-code')));
    await tester.pump();

    expect(find.text('请在 Host 上确认以下配对码'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(Card), matching: find.text('123456')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });
}

class _Pairer implements DevicePairer {
  @override
  Future<PairedDevice> pair(String rawPayload) =>
      throw UnimplementedError();
}

class _DiscoveryPairer implements DiscoveredDevicePairer {
  _DiscoveryPairer(this.host);

  final PairingCandidate host;
  int requestCalls = 0;

  @override
  Future<PairingRequestExchange> request(PairingCandidate candidate) async {
    requestCalls++;
    return PairingRequestExchange(
      attempt: PairingAttempt(
        candidate: host,
        requestId: 'request-id',
        clientNonce: 'client-nonce',
        state: PairingRequestState.pending,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
        localPollDeadline:
            DateTime.now().toUtc().add(const Duration(minutes: 2)),
        confirmationCode: '123456',
      ),
    );
  }

  @override
  Future<PairingRequestExchange> refresh(PairingAttempt attempt) =>
      throw UnimplementedError();
}
