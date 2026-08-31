import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../devices/device_models.dart';
import '../devices/device_registry.dart';
import '../devices/device_session.dart';
import '../devices/local_device_descriptor.dart';
import '../features/connection/pair_device_screen.dart';
import '../features/home/remote_home_screen.dart';
import '../discovery/resolving_gateway_transport.dart';
import '../gateway/demo_gateway_client.dart';
import '../gateway/gateway_client.dart';
import '../pairing/pairing_service.dart';

class CodePetRemoteApp extends StatefulWidget {
  const CodePetRemoteApp({super.key, this.includeDemoDevices = false});
  final bool includeDemoDevices;
  @override State<CodePetRemoteApp> createState() => _CodePetRemoteAppState();
}

class _CodePetRemoteAppState extends State<CodePetRemoteApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final DeviceRegistry _registry = DeviceRegistry(metadata: PreferencesMetadataStore(), credentials: const SecureCredentialStore());
  final LocalDeviceDescriptorProvider _descriptorProvider = LocalDeviceDescriptorProvider();
  final List<DeviceSession> _sessions = [];
  int _selectedIndex = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
          final device = await GatewayV1PairingService(registry: _registry, descriptorProvider: _descriptorProvider).pair(payload);
          final session = await _sessionFor(device);
          if (session != null) _sessions.add(session);
        }
      }
      for (final device in await _registry.load()) {
        if (_sessions.any((session) => session.device.deviceId == device.deviceId)) continue;
        final session = await _sessionFor(device);
        if (session != null) _sessions.add(session);
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

  Future<DeviceSession?> _sessionFor(PairedDevice device) async {
    final key = device.credentialKeyRef;
    final credential = key == null ? null : await _registry.credentials.read(key);
    final gateway = Uri.tryParse(device.preferredEndpoint ?? '');
    if (credential == null || gateway == null || device.tlsFingerprint == null || device.clientId == null) return null;
    final clientDevice = await _descriptorProvider.load();
    var preferredGateway = gateway;
    return DeviceSession(
      device: device,
      clientFactory: () => ProtocolGatewayClient(
        transport: ResolvingPinnedGatewayTransport(deviceId: device.deviceId, preferredGatewayUri: preferredGateway, credential: credential, certSha256: device.tlsFingerprint!),
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
      ),
    );
  }

  void _openAddDevice() {
    _navigatorKey.currentState!.push<void>(MaterialPageRoute(builder: (_) => PairDeviceScreen(
      pairingService: GatewayV1PairingService(registry: _registry, descriptorProvider: _descriptorProvider),
      onPaired: (device) async {
        final session = await _sessionFor(device);
        if (session == null) throw StateError('Credential was not stored securely');
        final index = await replaceDeviceSession(_sessions, session);
        if (!mounted) return;
        setState(() => _selectedIndex = index);
        _navigatorKey.currentState!.pop();
        unawaited(session.connect());
      },
      onAddDemo: widget.includeDemoDevices ? () async {} : null,
    )));
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

  @override void dispose() { for (final session in _sessions) { session.dispose(); } super.dispose(); }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: 'CodePet Remote', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF326B66)), useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF7F9F8), inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
    home: _loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) : RemoteHomeScreen(
      sessions: _sessions, selectedIndex: _selectedIndex,
      onSelectDevice: (index) => setState(() => _selectedIndex = index), onAddDevice: _openAddDevice, onOpenSettings: _openSettings,
    ),
  );
}
