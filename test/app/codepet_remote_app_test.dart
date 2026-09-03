import 'dart:async';

import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/application/ports/device_identity.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/discovery/codepet_discovery.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App owns the continuous Host discovery lifecycle', (tester) async {
    final directory = _HostDirectory();

    await tester.pumpWidget(CodePetRemoteApp(
      registry: DeviceRegistry(
        metadata: _Metadata(),
        credentials: _Credentials(),
      ),
      descriptorProvider: const _DescriptorProvider(),
      hostDirectory: directory,
      gatewayClientBuilder: ({
        required device,
        required credential,
        required clientDevice,
        required debugAndroidEmulatorGatewayUri,
      }) => _GatewayClient(),
    ));
    await tester.pumpAndSettle();

    expect(directory.startCalls, 1);
    expect(directory.stopCalls, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(directory.stopCalls, 1);
  });

  testWidgets('Host pairing advertisement opens a Remote confirmation prompt',
      (tester) async {
    final directory = _HostDirectory();
    await tester.pumpWidget(CodePetRemoteApp(
      registry: DeviceRegistry(
        metadata: _Metadata(),
        credentials: _Credentials(),
      ),
      descriptorProvider: const _DescriptorProvider(),
      hostDirectory: directory,
      gatewayClientBuilder: ({
        required device,
        required credential,
        required clientDevice,
        required debugAndroidEmulatorGatewayUri,
      }) => _GatewayClient(),
    ));
    await tester.pumpAndSettle();

    directory.advertisements.add(DiscoveredCodePetHost(
      instanceName: 'Studio Mac._codepet._tcp.local.',
      host: '192.168.1.10',
      port: 47622,
      txt: {
        'id': 'host-invitation',
        'name': 'Studio Mac',
        'fp': 'a' * 64,
        'vmin': '1',
        'vmax': '1',
        'pair': '1',
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('收到设备配对请求'), findsOneWidget);
    expect(find.text('Studio Mac 希望与这台设备建立安全连接。'), findsOneWidget);
    expect(find.text('接受并连接'), findsOneWidget);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(find.text('收到设备配对请求'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await directory.advertisements.close();
  });

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

class _HostDirectory implements CodePetHostDirectory {
  int startCalls = 0;
  int stopCalls = 0;
  final StreamController<DiscoveredCodePetHost> advertisements =
      StreamController<DiscoveredCodePetHost>.broadcast();

  @override
  DiscoveredCodePetHost? currentHost(String deviceId) => null;

  @override
  List<DiscoveredCodePetHost> currentHosts() => const [];

  @override
  void start() {
    startCalls++;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Stream<DiscoveredCodePetHost> watchHost(String deviceId) =>
      const Stream.empty();

  @override
  Stream<DiscoveredCodePetHost> watchHosts() => advertisements.stream;
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
  Future<GatewayProvider> describeProvider(String providerId) =>
      throw UnimplementedError();

  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async => const ConversationPage(
        conversations: [],
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async => ConversationSnapshot(
        detail: ConversationDetail(summary: conversation),
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async =>
      const ConversationInteraction(selection: TurnSendSelection());

  @override
  Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();

  @override
  Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();

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
