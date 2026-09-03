import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/domain/paired_device.dart';
import '../devices/device_registry.dart';
import '../application/ports/device_repository.dart';
import '../application/ports/device_identity.dart';
import '../application/pairing/pair_device.dart';
import '../application/sessions/device_session.dart';
import '../admission/lan_admission.dart';
import '../channel/channel.dart';
import '../core/domain/models.dart';
import '../application/ports/gateway_client.dart';
import '../application/ports/pairing_gateway.dart';
import '../devices/local_device_descriptor.dart';
import '../features/connection/pair_device_screen.dart';
import '../features/common/app_toast.dart';
import '../features/home/remote_home_screen.dart';
import '../gateway/demo_gateway_client.dart';
import '../gateway/gateway_client.dart';

typedef RestoredGatewayClientBuilder = GatewayClient Function({
  required PairedDevice device,
  required String credential,
  required DeviceDescriptor clientDevice,
  required Uri? debugAndroidEmulatorGatewayUri,
});

class CodePetRemoteApp extends StatefulWidget {
  const CodePetRemoteApp({
    super.key,
    this.includeDemoDevices = false,
    this.registry,
    this.descriptorProvider,
    this.gatewayClientBuilder,
    this.hostDirectory,
  });

  final bool includeDemoDevices;
  final DeviceRepository? registry;
  final DeviceDescriptorProvider? descriptorProvider;
  final RestoredGatewayClientBuilder? gatewayClientBuilder;
  final CodePetHostDirectory? hostDirectory;

  @override State<CodePetRemoteApp> createState() => _CodePetRemoteAppState();
}

class _CodePetRemoteAppState extends State<CodePetRemoteApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final DeviceRepository _registry;
  late final DeviceDescriptorProvider _descriptorProvider;
  late final CodePetHostDirectory _hostDirectory;
  late final bool _discoveryEnabled;
  StreamSubscription<DiscoveredCodePetHost>? _pairingAdvertisementSubscription;
  final Set<String> _handledPairingInvitations = {};
  final List<DeviceSession> _sessions = [];
  int _selectedIndex = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? DeviceRegistry(
      metadata: PreferencesMetadataStore(),
      credentials: const SecureCredentialStore(),
    );
    _descriptorProvider =
        widget.descriptorProvider ?? LocalDeviceDescriptorProvider();
    _hostDirectory = widget.hostDirectory ??
        MdnsCodePetHostDirectory(
          discovery: CodePetDiscovery(
            fallbackProbe: _probeDebugAndroidEmulatorHost,
          ),
        );
    _discoveryEnabled = !widget.includeDemoDevices &&
        (widget.hostDirectory != null || widget.gatewayClientBuilder == null);
    if (_discoveryEnabled) _hostDirectory.start();
    if (_discoveryEnabled) {
      _pairingAdvertisementSubscription = _hostDirectory.watchHosts().listen(
        _handlePairingAdvertisement,
      );
    }
    unawaited(_loadDevices());
  }

  Future<void> _loadDevices() async {
    if (widget.includeDemoDevices) {
      _addDemo('demo-studio', '工作室 Mac', 'studio');
      _addDemo('demo-laptop', '随身电脑', 'laptop');
    } else {
      const e2eMode = bool.fromEnvironment('CODEPET_E2E');
      if (e2eMode) {
        final payloadFile = File('/data/user/0/com.codepet.remote/files/pairing-payload.tmp');
        if (await payloadFile.exists()) {
          final payload = await payloadFile.readAsString();
          await payloadFile.delete();
          final device = await _pairer().pair(payload);
          final session = await _sessionFor(device);
          _sessions.add(session);
        }
      }
      for (final device in await _registry.load()) {
        if (_sessions.any((session) => session.device.deviceId == device.deviceId)) continue;
        final session = await _sessionFor(device);
        _sessions.add(session);
      }
    }
    if (mounted) setState(() => _loading = false);
    for (final session in _sessions.where((item) => item.device.autoConnect || item.device.connectionKind == DeviceConnectionKind.demo)) {
      unawaited(session.connect());
    }
  }

  void _addDemo(String id, String name, String profile) {
    _sessions.add(DeviceSession(
      device: PairedDevice(deviceId: id, displayName: name, connectionKind: DeviceConnectionKind.demo, preferredEndpoint: 'demo://$profile'),
      clientFactory: () => DemoGatewayClient(profileId: profile),
    ));
  }

  Future<DeviceSession> _sessionFor(PairedDevice device) async {
    final key = device.credentialKeyRef;
    String? credential;
    var credentialReadFailed = false;
    if (key != null) {
      try {
        credential = await _registry.readCredential(device);
      } catch (_) {
        credentialReadFailed = true;
      }
    }
    final gateway = Uri.tryParse(device.preferredEndpoint ?? '');
    final registrationError = credentialReadFailed
        ? '安全凭据读取失败，请忘记设备后重新配对。'
        : credential == null
            ? '安全凭据不存在，请忘记设备后重新配对。'
            : gateway == null ||
                    device.tlsFingerprint == null ||
                    device.clientId == null
                ? '设备注册信息不完整，请忘记设备后重新配对。'
                : null;
    if (registrationError != null) {
      return DeviceSession(
        device: device,
        clientFactory: () => throw StateError(registrationError),
        autoReconnect: false,
      );
    }
    final restoredCredential = credential!;
    final restoredGateway = gateway!;
    final reconnectSignals = _discoveryEnabled
        ? _hostDirectory.watchHost(device.deviceId).map<void>((_) {})
        : null;
    final clientDevice = await _descriptorProvider.load();
    final descriptorProvider = _descriptorProvider;
    var useDebugAndroidEmulatorAlias = false;
    if (descriptorProvider is DebugAndroidEmulatorProvider) {
      try {
        useDebugAndroidEmulatorAlias =
            await (descriptorProvider as DebugAndroidEmulatorProvider)
                .isDebugAndroidEmulator();
      } catch (_) {}
    }
    var preferredGateway = restoredGateway;
    return DeviceSession(
      device: device,
      clientFactory: () {
        final debugAndroidEmulatorGatewayUri = useDebugAndroidEmulatorAlias
            ? debugAndroidEmulatorGatewayCandidate(preferredGateway)
            : null;
        final builder = widget.gatewayClientBuilder;
        if (builder != null) {
          return builder(
            device: device,
            credential: restoredCredential,
            clientDevice: clientDevice,
            debugAndroidEmulatorGatewayUri:
                debugAndroidEmulatorGatewayUri,
          );
        }
        return ProtocolGatewayClient(
          transport: ResolvingPinnedGatewayTransport(
            deviceId: device.deviceId,
            preferredGatewayUri: preferredGateway,
            debugAndroidEmulatorGatewayUri:
                debugAndroidEmulatorGatewayUri,
            credential: restoredCredential,
            certSha256: device.tlsFingerprint!,
            hostDirectory: _discoveryEnabled ? _hostDirectory : null,
          ),
          clientId: device.clientId!, clientDevice: clientDevice, expectedDeviceId: device.deviceId, expectedIdentityFingerprint: device.tlsFingerprint!,
          onValidatedHostDescriptor: (descriptor) => _registry.updateHostDescriptor(
            deviceId: device.deviceId,
            clientId: device.clientId!,
            tlsFingerprint: device.tlsFingerprint!,
            descriptor: descriptor,
          ),
          onValidatedEndpoint: (endpoint) async {
            if (endpoint == preferredGateway) return;
            preferredGateway = endpoint;
            try {
              await _registry.updatePreferredEndpoint(device.deviceId, endpoint.toString());
            } catch (_) {}
          },
        );
      },
      reconnectSignals: reconnectSignals,
    );
  }

  void _openAddDevice() {
    _navigatorKey.currentState!.push<void>(MaterialPageRoute(builder: (_) => PairDeviceScreen(
      pairingService: _pairer(),
      discoveryService: _discoveredPairer(),
      connectedSessions: List.unmodifiable(_sessions),
      initialCandidates: _discoveryEnabled
          ? _hostDirectory
              .currentHosts()
              .where((host) => host.txt['fp'] != null)
              .map(_pairingCandidate)
              .toList()
          : const [],
      candidateUpdates: _discoveryEnabled
          ? _hostDirectory
              .watchHosts()
              .where((host) => host.txt['fp'] != null)
              .map(_pairingCandidate)
          : null,
      onRefreshDiscovery: _discoveryEnabled ? _hostDirectory.refresh : null,
      onPaired: (device) async {
        await _activatePairedDevice(device);
        if (!mounted) return;
        _navigatorKey.currentState!.pop();
      },
      onAddDemo: widget.includeDemoDevices ? () async {} : null,
    )));
  }

  DevicePairer _pairer() => PairDeviceUseCase(
        repository: _registry,
        descriptorProvider: _descriptorProvider,
        gateway: const LanPairingGateway(),
      );

  DiscoveredDevicePairer _discoveredPairer() =>
      PairDiscoveredDeviceUseCase(
        repository: _registry,
        descriptorProvider: _descriptorProvider,
        gateway: const LanPairingRequestGateway(),
      );

  Future<DiscoveredCodePetHost?> _probeDebugAndroidEmulatorHost() async {
    final provider = _descriptorProvider;
    if (provider is! DebugAndroidEmulatorProvider) return null;
    final emulatorProvider = provider as DebugAndroidEmulatorProvider;
    try {
      if (!await emulatorProvider.isDebugAndroidEmulator()) return null;
      return AndroidEmulatorCodePetHostProbe().probe();
    } catch (_) {
      return null;
    }
  }

  PairingCandidate _pairingCandidate(DiscoveredCodePetHost host) =>
      PairingCandidate(
        deviceId: host.txt['id']!,
        displayName: host.txt['name'] ?? host.instanceName,
        host: host.host,
        port: host.port,
        tlsFingerprint: host.txt['fp']!,
        hostInitiated: host.txt['pair'] == '1',
      );

  Future<void> _activatePairedDevice(PairedDevice device) async {
    final session = await _sessionFor(device);
    final index = await replaceDeviceSession(_sessions, session);
    if (!mounted) {
      session.dispose();
      return;
    }
    setState(() => _selectedIndex = index);
    unawaited(session.connect());
  }

  void _handlePairingAdvertisement(DiscoveredCodePetHost host) {
    final deviceId = host.txt['id'];
    final fingerprint = host.txt['fp'];
    if (deviceId == null || fingerprint == null) return;
    final invitationKey = '$deviceId:$fingerprint';
    if (host.txt['pair'] != '1') {
      _handledPairingInvitations.remove(invitationKey);
      return;
    }
    if (_sessions.any((session) =>
            session.device.deviceId == deviceId &&
            (session.connectionState == DeviceConnectionState.online ||
                session.connectionState == DeviceConnectionState.connecting)) ||
        !_handledPairingInvitations.add(invitationKey)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_confirmHostInvitation(host));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _confirmHostInvitation(DiscoveredCodePetHost host) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final displayName = host.txt['name'] ?? host.instanceName;
    final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('收到设备配对请求'),
            content: Text('$displayName 希望与这台设备建立安全连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('接受并连接'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted || !mounted) return;
    try {
      var exchange = await _discoveredPairer().request(_pairingCandidate(host));
      BuildContext? waitingDialogContext;
      Future<void>? waitingDialog;
      if (exchange.registration == null && mounted) {
        final waitingContext = _navigatorKey.currentContext;
        if (waitingContext != null && waitingContext.mounted) {
          waitingDialog = showDialog<void>(
            context: waitingContext,
            barrierDismissible: false,
            builder: (context) {
              waitingDialogContext = context;
              return AlertDialog(
                title: const Text('核对配对码'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('请确认 Host 上显示相同配对码'),
                    const SizedBox(height: 12),
                    Text(
                      exchange.attempt.confirmationCode,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ],
                ),
              );
            },
          );
        }
      }
      try {
        while (exchange.registration == null &&
            exchange.attempt.state == PairingRequestState.pending &&
            exchange.attempt.localPollDeadline.isAfter(DateTime.now().toUtc())) {
          await Future<void>.delayed(const Duration(seconds: 1));
          exchange = await _discoveredPairer().refresh(exchange.attempt);
        }
      } finally {
        final dialogContext = waitingDialogContext;
        if (dialogContext != null && dialogContext.mounted) {
          Navigator.pop(dialogContext);
        }
        await waitingDialog;
      }
      final registration = exchange.registration;
      if (registration == null) {
        throw StateError('Host 未接受或配对请求已过期');
      }
      await _activatePairedDevice(registration.device);
    } catch (error) {
      if (!mounted) return;
      final errorContext = _navigatorKey.currentContext;
      if (errorContext != null && errorContext.mounted) {
        await showDialog<void>(
          context: errorContext,
          builder: (context) => AlertDialog(
            title: const Text('配对失败'),
            content: Text(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    }
  }

  void _openSettings() {
    _navigatorKey.currentState!.push<void>(MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('App 设置')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const ListTile(leading: Icon(Icons.security), title: Text('Gateway v1'), subtitle: Text('设备凭据保存在 Android Keystore 支持的安全存储中；会话和事件游标不落盘。')),
        for (final session in _sessions.where((item) => item.device.connectionKind == DeviceConnectionKind.pairedGateway))
          ListTile(
            title: Text(session.device.effectiveName), subtitle: Text(session.device.deviceId),
            trailing: TextButton(child: const Text('忘记'), onPressed: () async {
              await session.disconnect();
              await _registry.forget(session.device);
              if (!mounted) return;
              setState(() { _sessions.remove(session); _selectedIndex = _sessions.isEmpty ? 0 : _selectedIndex.clamp(0, _sessions.length - 1); });
            }),
          ),
      ]),
    )));
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session.dispose();
    }
    unawaited(_pairingAdvertisementSubscription?.cancel());
    if (_discoveryEnabled) unawaited(_hostDirectory.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: 'CodePet Remote', debugShowCheckedModeBanner: false,
    builder: (context, child) => AppToastHost(child: child!),
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF326B66)), useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF7F9F8), inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
    home: _loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) : RemoteHomeScreen(
      sessions: _sessions, selectedIndex: _selectedIndex,
      onSelectDevice: (index) => setState(() => _selectedIndex = index), onAddDevice: _openAddDevice, onOpenSettings: _openSettings,
    ),
  );
}
