import 'dart:async';
import 'dart:io';
import 'package:codepet_connection_engine/codepet_connection_engine.dart' as ce;
import '../gateway/connection/device_connection_routes.dart';

import 'package:flutter/material.dart';
import 'channel_preferences.dart';
import 'connection_environment_observer.dart';
import '../gateway/webrtc/device_registration.dart';
import 'app_notifications.dart';
import '../core/domain/notification.dart';
import '../features/conversations/conversation_detail_screen.dart';

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
import '../diagnostics/app_log.dart';
import '../diagnostics/app_trace_recorder.dart';
import '../features/connection/pair_device_screen.dart';
import '../features/common/app_toast.dart';
import '../features/home/remote_home_screen.dart';
import '../features/settings/app_settings_screen.dart';
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
    this.logExporter,
    this.webRtcEnabled = false,
    this.signalingService,
    this.notifications,
  });

  final AppNotifications? notifications;
  final bool includeDemoDevices;
  final bool webRtcEnabled;
  final String? signalingService;
  final DeviceRepository? registry;
  final DeviceDescriptorProvider? descriptorProvider;
  final RestoredGatewayClientBuilder? gatewayClientBuilder;
  final CodePetHostDirectory? hostDirectory;
  final Future<String> Function()? logExporter;

  @override State<CodePetRemoteApp> createState() => _CodePetRemoteAppState();
}

class _CodePetRemoteAppState extends State<CodePetRemoteApp> {
  final AppLog _log = AppLog.named('app');
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final DeviceRepository _registry;
  late final DeviceDescriptorProvider _descriptorProvider;
  late final CodePetHostDirectory _hostDirectory;
  late final bool _discoveryEnabled;
  StreamSubscription<DiscoveredCodePetHost>? _pairingAdvertisementSubscription;
  final Set<String> _handledPairingInvitations = {};
  final List<DeviceSession> _sessions = [];
  ConnectionEnvironmentObserver? _connectionEnvironment;
  final _connectionBudget = ce.CandidateBudget(limit: 8);
  int _selectedIndex = 0;
  bool _loading = true;
  late bool _savedWebRtcEnabled;
  late String? _savedSignalingService;
  late final SignalingDeviceRegistration _signalRegistration;
  Timer? _signalRegistrationRetry;

  @override
  void initState() {
    super.initState();
    _savedWebRtcEnabled = widget.webRtcEnabled;
    _savedSignalingService = widget.signalingService;
    widget.notifications?.onOpen = (target) => unawaited(_openNotification(target));
    _registry = widget.registry ?? DeviceRegistry(
      metadata: PreferencesMetadataStore(),
      credentials: const SecureCredentialStore(),
      logger: _log,
    );
    _signalRegistration = SignalingDeviceRegistration(
      deviceId: _registry.loadOrCreateClientId,
    );
    unawaited(_retrySignalingRegistration());
    _scheduleSignalingRegistrationRetry();
    _descriptorProvider =
        widget.descriptorProvider ?? LocalDeviceDescriptorProvider(logger: _log);
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
        onError: (Object error, StackTrace stackTrace) {
          _log.warning(
            'Host discovery advertisement stream failed',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
    _connectionEnvironment = ConnectionEnvironmentObserver((optimize) {
      for (final session in _sessions) { session.reconcileConnection(optimize: optimize); }
    });
    unawaited(_loadDevices());
  }

  Future<void> _loadDevices() async {
    _log.info('Loading registered devices');
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
      final devices = await _registry.load();
      _log.info('Loaded ${devices.length} registered device(s)');
      for (final device in devices) {
        if (_sessions.any((session) => session.device.deviceId == device.deviceId)) continue;
        final session = await _sessionFor(device);
        _sessions.add(session);
      }
    }
    if (mounted) setState(() => _loading = false);
    _syncNotificationSessions();
    final notificationTarget = widget.notifications?.pendingTarget;
    if (notificationTarget != null) {
      widget.notifications!.pendingTarget = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openNotification(notificationTarget)));
    }
    for (final session in _sessions.where((item) => item.device.autoConnect || item.device.connectionKind == DeviceConnectionKind.demo)) {
      unawaited(session.connect());
    }
  }

  void _addDemo(String id, String name, String profile) {
    final sessionLog = AppLog.named('session.$id');
    final traceRecorder = AppTraceRecorder(logger: sessionLog);
    _sessions.add(DeviceSession(
      onLiveEvent: (event) => _notificationEvent(id, name, event),
      onConversationSnapshot: (items) => _notificationSnapshot(id, name, items),
      device: PairedDevice(deviceId: id, displayName: name, connectionKind: DeviceConnectionKind.demo, preferredEndpoint: 'demo://$profile'),
      clientFactory: () => DemoGatewayClient(profileId: profile),
      logger: sessionLog,
      traceRecorder: traceRecorder,
    ));
  }

  Future<DeviceSession> _sessionFor(PairedDevice device) async {
    final key = device.credentialKeyRef;
    String? credential;
    var credentialReadFailed = false;
    if (key != null) {
      try {
        credential = await _registry.readCredential(device);
        _log.fine('Credential lookup completed for device ${device.deviceId}');
      } catch (error, stackTrace) {
        credentialReadFailed = true;
        _log.warning(
          'Credential lookup failed for device ${device.deviceId}',
          error: error,
          stackTrace: stackTrace,
        );
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
      _log.warning(
        'Registered device ${device.deviceId} cannot create a session: '
        '$registrationError',
      );
      return DeviceSession(
        device: device,
        clientFactory: () => throw StateError(registrationError),
        autoReconnect: false,
        logger: AppLog.named('session.${device.deviceId}'),
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
    final sessionLog = AppLog.named('session.${device.deviceId}');
    final traceRecorder = AppTraceRecorder(logger: sessionLog);
    return DeviceSession(
      device: device,
      onLiveEvent: (event) => _notificationEvent(device.deviceId, device.displayName, event),
      onConversationSnapshot: (items) => _notificationSnapshot(device.deviceId, device.displayName, items),
      logger: sessionLog,
      traceRecorder: traceRecorder,
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
          transport: createDeviceConnection(
            signalingService: _savedSignalingService, webRtcEnabled: _savedWebRtcEnabled,
            budget: _connectionBudget, deviceId: device.deviceId, preferredGatewayUri: preferredGateway,
            debugAndroidEmulatorGatewayUri: debugAndroidEmulatorGatewayUri,
            credential: restoredCredential, certSha256: device.tlsFingerprint!,
            hostDirectory: _discoveryEnabled ? _hostDirectory : null,
          ),
          clientId: device.clientId!, clientDevice: clientDevice, expectedDeviceId: device.deviceId, expectedIdentityFingerprint: device.tlsFingerprint!,
          traceRecorder: traceRecorder,
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
              await _registry.updatePreferredEndpoint(
                deviceId: device.deviceId,
                clientId: device.clientId!,
                tlsFingerprint: device.tlsFingerprint!,
                endpoint: endpoint.toString(),
              );
            } catch (error, stackTrace) {
              _log.warning(
                'Preferred endpoint persistence failed for device '
                '${device.deviceId}',
                error: error,
                stackTrace: stackTrace,
              );
            }
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
      onForgetDevice: _forgetDevice,
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
      logger: _log,
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
        gateway: LanPairingGateway(signalingService: _savedSignalingService),
    logger: AppLog.named('pairing'),
      );

  DiscoveredDevicePairer _discoveredPairer() =>
      PairDiscoveredDeviceUseCase(
        repository: _registry,
        descriptorProvider: _descriptorProvider,
        gateway: const LanPairingRequestGateway(),
        logger: AppLog.named('pairing'),
      );

  Future<DiscoveredCodePetHost?> _probeDebugAndroidEmulatorHost() async {
    final provider = _descriptorProvider;
    if (provider is! DebugAndroidEmulatorProvider) return null;
    final emulatorProvider = provider as DebugAndroidEmulatorProvider;
    try {
      if (!await emulatorProvider.isDebugAndroidEmulator()) return null;
      return await AndroidEmulatorCodePetHostProbe().probe();
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
    _syncNotificationSessions();
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
    _log.info('Host pairing invitation received for device $deviceId');
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
    _log.info(
      'Host pairing invitation ${accepted ? 'accepted' : 'rejected'} '
      'for device ${host.txt['id'] ?? 'unknown'}',
    );
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
    } catch (error, stackTrace) {
      _log.warning(
        'Host-initiated pairing failed for device ${host.txt['id'] ?? 'unknown'}',
        error: error,
        stackTrace: stackTrace,
      );
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

  Future<void> _forgetDevice(DeviceSession session) async {
    await session.disconnect();
    await _registry.forget(session.device);
    await widget.notifications?.coordinator.forgetDevice(session.device.deviceId);
    session.dispose();
    if (!mounted) return;
    setState(() {
      final index = _sessions.indexOf(session);
      if (index < 0) return;
      _sessions.removeAt(index);
      if (index < _selectedIndex) _selectedIndex--;
      _selectedIndex = _sessions.isEmpty
          ? 0
          : _selectedIndex.clamp(0, _sessions.length - 1);
    });
    _syncNotificationSessions();
  }

  void _notificationSnapshot(String id, String name, List<ConversationSummary> items) {
    final notifications = widget.notifications;
    if (notifications != null) unawaited(notifications.coordinator.snapshot(id, name, items));
  }

  void _notificationEvent(String id, String name, GatewayEvent event) {
    final notifications = widget.notifications;
    if (notifications == null ||
        (event is! TurnUpsertedEvent && event is! ApprovalChangedEvent &&
         event is! ConversationUpsertedEvent)) {
      return;
    }
    if (event is TurnUpsertedEvent && !event.turn.status.isTerminal) return;
    String? conversationId;
    String? providerId;
    if (event is TurnUpsertedEvent) {
      conversationId = event.turn.conversationId;
      providerId = event.turn.providerId;
    } else if (event is ApprovalChangedEvent) {
      conversationId = event.conversationId;
      providerId = event.approval.resource?.providerId;
    }
    ConversationSummary? summary;
    for (final session in _sessions.where((item) => item.device.deviceId == id)) {
      for (final item in session.conversations) {
        if ((item.id == conversationId || item.resource?.key == conversationId) &&
            (providerId == null || item.providerId == providerId || item.resource?.providerId == providerId)) {
          summary = item;
          break;
        }
      }
    }
    unawaited(notifications.coordinator.event(id, name, event, summary));
  }

  void _syncNotificationSessions() {
    final notifications = widget.notifications;
    if (notifications == null) return;
    notifications.hasSessions = _sessions.isNotEmpty;
    unawaited(notifications.syncConnectionService().catchError((Object error) {
      _log.warning('Unable to keep background connection', error: error);
    }));
  }

  bool _openingNotification = false;
  Future<void> _openNotification(NotificationTarget target) async {
    if (!mounted) return;
    if (_loading || _openingNotification) {
      widget.notifications?.pendingTarget = target;
      return;
    }
    _openingNotification = true;
    try {
      final index = _sessions.indexWhere((item) => item.device.deviceId == target.deviceId);
      if (index < 0) throw StateError('设备已移除，请重新配对');
      final session = _sessions[index];
      setState(() => _selectedIndex = index);
      if (session.connectionState == DeviceConnectionState.connecting) {
        // The initial auto-connect owns this attempt. Wait without starting a
        // competing connection or accepting a lease from a replaced session.
        for (var i = 0; i < 150 && session.connectionState == DeviceConnectionState.connecting; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (!mounted || !_sessions.contains(session)) return;
        }
      } else if (session.runtimeLease == null) {
        await session.connect();
      }
      final lease = session.runtimeLease;
      if (lease == null) throw StateError('设备未连接，请连接后重试');
      if (!session.handshake!.providers.any((provider) => provider.id == target.providerId)) {
        throw StateError('对应的 Provider 已不可用');
      }
      final now = DateTime.now();
      final snapshot = await lease.getConversation(ConversationSummary(
        id: target.conversationId, providerId: target.providerId, title: '会话',
        status: ConversationStatus.idle, permissionLevel: PermissionLevel.readOnly,
        createdAt: now, updatedAt: now,
        resource: RoutedResourceId(providerId: target.providerId, nativeResourceId: target.conversationId),
      ));
      if (!mounted || !_sessions.contains(session) || !session.ownsRuntimeLease(lease)) return;
      await widget.notifications?.coordinator.acknowledge(target);
      _navigatorKey.currentState!.popUntil((route) => route.isFirst);
      unawaited(_navigatorKey.currentState!.push<void>(MaterialPageRoute(
        settings: RouteSettings(arguments: target),
        builder: (_) => ConversationDetailScreen(session: session, conversation: snapshot.detail.summary,
          notificationTarget: target),
      )));
    } catch (error) {
      _log.warning('Unable to open notification conversation', error: error);
      if (mounted && _navigatorKey.currentContext != null) {
        ScaffoldMessenger.of(_navigatorKey.currentContext!).showSnackBar(SnackBar(
          content: const Text('暂时无法打开此会话，请检查设备连接后重试'),
          action: SnackBarAction(label: '重试', onPressed: () => unawaited(_openNotification(target))),
        ));
      }
    } finally {
      _openingNotification = false;
      final next = widget.notifications?.pendingTarget;
      if (mounted && next != null) {
        widget.notifications!.pendingTarget = null;
        unawaited(_openNotification(next));
      }
    }
  }

  void _openSettings() {
    _navigatorKey.currentState!.push<void>(MaterialPageRoute(
      builder: (_) => AppSettingsScreen(
        notificationPreferences: widget.notifications?.coordinator.preferences,
        onNotificationsChanged: widget.notifications?.changePreferences,
        notificationsAllowed: widget.notifications?.adapter.isAllowed,
        openNotificationSettings: widget.notifications?.adapter.openSettings,
        webRtcEnabled: _savedWebRtcEnabled,
        activeWebRtcEnabled: widget.webRtcEnabled,
          signalingService: _savedSignalingService,
          onSignalingServiceChanged: (address) async {
            await ChannelPreferences.saveSignalingService(address);
            _savedSignalingService = address;
            _scheduleSignalingRegistrationRetry();
            if (address != null) {
              await _signalRegistration.register(address, force: true);
            }
          },
          onWebRtcChanged: (enabled) async {
          await ChannelPreferences.saveWebRtcEnabled(enabled);
          _savedWebRtcEnabled = enabled;
        },
        exportLogs: widget.logExporter ?? AppLog.exportLogs,
        logger: _log,
      ),
    ));
  }

  @override
  void dispose() {
    _connectionEnvironment?.dispose();
    _signalRegistrationRetry?.cancel();
    widget.notifications?.dispose();
    for (final session in _sessions) {
      session.dispose();
    }
    unawaited(_pairingAdvertisementSubscription?.cancel());
    if (_discoveryEnabled) unawaited(_hostDirectory.stop());
    super.dispose();
  }

  Future<void> _retrySignalingRegistration() async {
    final service = _savedSignalingService;
    if (service == null) return;
    try {
      await _signalRegistration.register(service);
    } catch (_) {
      /* The adapter records a sanitized diagnostic for background retries. */
    }
  }

  void _scheduleSignalingRegistrationRetry() {
    _signalRegistrationRetry?.cancel();
    _signalRegistrationRetry = _savedSignalingService == null
        ? null
        : Timer.periodic(
            const Duration(seconds: 30),
            (_) => unawaited(_retrySignalingRegistration()),
          );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    navigatorObservers: [if (widget.notifications != null) widget.notifications!.observer],
    title: 'CodePet Remote', debugShowCheckedModeBanner: false,
    builder: (context, child) => AppToastHost(child: child!),
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF326B66)), useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF7F9F8), inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
    home: _loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) : RemoteHomeScreen(
      sessions: _sessions, selectedIndex: _selectedIndex,
      onSelectDevice: (index) => setState(() => _selectedIndex = index), onAddDevice: _openAddDevice, onOpenSettings: _openSettings,
    ),
  );
}
