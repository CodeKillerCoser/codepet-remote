import 'dart:async';

import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/devices/local_device_descriptor.dart';
import 'package:codepet_remote/core/ports/gateway_client.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ordinary app rebuild restores the registry credential and auto-connects',
    (tester) async {
      final metadata = _Metadata();
      final credentials = _Credentials();
      await DeviceRegistry(
        metadata: metadata,
        credentials: credentials,
      ).register(_persistedDevice, 'restored-credential');
      final restoredCredentials = <String>[];
      var connections = 0;

      CodePetRemoteApp app(DeviceRegistry registry) => CodePetRemoteApp(
            registry: registry,
            descriptorProvider: const _DescriptorProvider(),
            gatewayClientBuilder: ({
              required device,
              required credential,
              required clientDevice,
              required debugAndroidEmulatorGatewayUri,
            }) {
              restoredCredentials.add(credential);
              return _GatewayClient(onConnect: () {
                connections++;
              });
            },
          );

      await tester.pumpWidget(app(DeviceRegistry(
        metadata: metadata,
        credentials: credentials,
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('device-host-persisted')), findsOneWidget);
      expect(find.text('Real Host Name'), findsOneWidget);
      expect(find.text('TestOS 1'), findsOneWidget);
      expect(restoredCredentials, ['restored-credential']);
      expect(connections, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(DeviceRegistry(
        metadata: metadata,
        credentials: credentials,
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('device-host-persisted')), findsOneWidget);
      expect(restoredCredentials, [
        'restored-credential',
        'restored-credential',
      ]);
      expect(connections, 2);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(DeviceRegistry(
        metadata: _Metadata(),
        credentials: _Credentials(),
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('device-host-persisted')), findsNothing);
      expect(find.text('还没有设备'), findsOneWidget);
      expect(connections, 2);
    },
  );

  testWidgets(
    'missing secure credential keeps the registered device visible as failed',
    (tester) async {
      final metadata = _Metadata();
      await DeviceRegistry(
        metadata: metadata,
        credentials: _Credentials(),
      ).save([_persistedDevice]);
      var clientBuilds = 0;

      await tester.pumpWidget(CodePetRemoteApp(
        registry: DeviceRegistry(
          metadata: metadata,
          credentials: _Credentials(),
        ),
        descriptorProvider: const _DescriptorProvider(),
        gatewayClientBuilder: ({
          required device,
          required credential,
          required clientDevice,
          required debugAndroidEmulatorGatewayUri,
        }) {
          clientBuilds++;
          return _GatewayClient();
        },
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('device-host-persisted')), findsOneWidget);
      expect(find.text('设备连接失败'), findsOneWidget);
      expect(find.textContaining('安全凭据不存在'), findsOneWidget);
      expect(clientBuilds, 0);
    },
  );

  testWidgets(
    'passes a per-Host ephemeral alias only for a debug Android emulator',
    (tester) async {
      final metadata = _Metadata();
      final credentials = _Credentials();
      final device = _persistedDevice.withPreferredEndpoint(
        'wss://192.168.0.105:43210/custom/gateway?mode=paired',
      );
      await DeviceRegistry(
        metadata: metadata,
        credentials: credentials,
      ).register(device, 'restored-credential');
      final aliases = <Uri?>[];

      await tester.pumpWidget(CodePetRemoteApp(
        registry: DeviceRegistry(
          metadata: metadata,
          credentials: credentials,
        ),
        descriptorProvider: const _DescriptorProvider(
          debugAndroidEmulator: true,
        ),
        gatewayClientBuilder: ({
          required device,
          required credential,
          required clientDevice,
          required debugAndroidEmulatorGatewayUri,
        }) {
          aliases.add(debugAndroidEmulatorGatewayUri);
          return _GatewayClient();
        },
      ));
      await tester.pumpAndSettle();

      expect(aliases, [
        Uri.parse(
          'wss://10.0.2.2:43210/custom/gateway?mode=paired',
        ),
      ]);
      final reloaded = await DeviceRegistry(
        metadata: metadata,
        credentials: credentials,
      ).load();
      expect(reloaded.single.preferredEndpoint, device.preferredEndpoint);
      expect(reloaded.single.endpointHints, device.endpointHints);
    },
  );
}

const _persistedDevice = PairedDevice(
  deviceId: 'host-persisted',
  displayName: 'Persisted Host Name',
  descriptor: DeviceDescriptor(
    deviceName: 'Persisted Host Name',
    operatingSystem: 'TestOS',
    systemVersion: '0',
  ),
  tlsFingerprint: 'fingerprint',
  credentialKeyRef: 'secure:host-persisted',
  clientId: 'remote-client',
  preferredEndpoint: 'wss://host.test/remote/v1/gateway',
  autoConnect: true,
  connectionKind: DeviceConnectionKind.pairedGateway,
);

class _DescriptorProvider
    implements DeviceDescriptorProvider, DebugAndroidEmulatorProvider {
  const _DescriptorProvider({this.debugAndroidEmulator = false});

  final bool debugAndroidEmulator;

  @override
  Future<bool> isDebugAndroidEmulator() async => debugAndroidEmulator;

  @override
  Future<DeviceDescriptor> load() async => const DeviceDescriptor(
        deviceName: 'Remote Phone',
        operatingSystem: 'Android',
        systemVersion: '16',
      );
}

class _GatewayClient implements GatewayClient {
  _GatewayClient({this.onConnect});

  final VoidCallback? onConnect;
  final StreamController<GatewayEvent> controller =
      StreamController<GatewayEvent>.broadcast();

  @override
  Stream<GatewayEvent> get events => controller.stream;

  @override
  String? get latestEventCursor => 'handshake';

  @override
  GatewayEventWindow openEventWindow() =>
      GatewayEventWindow.forStream('handshake', events);

  @override
  Future<GatewayHandshake> connect() async {
    onConnect?.call();
    return const GatewayHandshake(
      protocolVersion: 1,
      serverName: 'Test',
      serverVersion: '1',
      providers: [],
      eventCursor: 'handshake',
      deviceDescriptor: DeviceDescriptor(
        deviceName: 'Real Host Name',
        operatingSystem: 'TestOS',
        systemVersion: '1',
      ),
    );
  }

  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async => const ConversationPage(
        conversations: [],
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async => ConversationSnapshot(
        detail: ConversationDetail(summary: conversation),
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot}) => throw UnimplementedError();

  @override
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();

  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

class _Metadata implements DeviceMetadataStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _Credentials implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
