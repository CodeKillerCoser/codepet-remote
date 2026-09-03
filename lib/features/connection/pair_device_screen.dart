import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../application/pairing/pair_device.dart';
import '../../application/ports/pairing_gateway.dart';
import '../../application/sessions/device_session.dart';
import '../../core/domain/paired_device.dart';

class PairDeviceScreen extends StatefulWidget {
  const PairDeviceScreen({
    super.key,
    required this.pairingService,
    required this.onPaired,
    this.discoveryService,
    this.connectedSessions = const [],
    this.initialCandidates = const [],
    this.candidateUpdates,
    this.onRefreshDiscovery,
    this.onAddDemo,
  });
  final DevicePairer pairingService;
  final DiscoveredDevicePairer? discoveryService;
  final List<DeviceSession> connectedSessions;
  final List<PairingCandidate> initialCandidates;
  final Stream<PairingCandidate>? candidateUpdates;
  final Future<void> Function()? onRefreshDiscovery;
  final Future<void> Function(PairedDevice device) onPaired;
  final Future<void> Function()? onAddDemo;
  @override State<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends State<PairDeviceScreen> {
  bool _busy = false;
  String? _error;
  final Map<String, PairingCandidate> _hosts = {};
  final Set<DeviceSession> _listenedSessions = {};
  StreamSubscription<PairingCandidate>? _hostSubscription;
  Timer? _pairingPoll;
  PairingAttempt? _attempt;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    for (final host in widget.initialCandidates) {
      _rememberHost(host);
    }
    _syncSessionListeners();
    _hostSubscription = widget.candidateUpdates?.listen((host) {
      if (!mounted) return;
      setState(() => _rememberHost(host));
    });
  }

  @override
  void didUpdateWidget(PairDeviceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSessionListeners();
  }

  void _syncSessionListeners() {
    final desired = widget.connectedSessions.toSet();
    for (final session in _listenedSessions.difference(desired)) {
      session.removeListener(_sessionChanged);
    }
    for (final session in desired.difference(_listenedSessions)) {
      session.addListener(_sessionChanged);
    }
    _listenedSessions
      ..clear()
      ..addAll(desired);
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  void _rememberHost(PairingCandidate host) {
    _hosts[host.deviceId] = host;
  }

  Future<void> _pair(String value) async {
    if (_busy || value.trim().isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final device = await widget.pairingService.pair(value.trim());
      await widget.onPaired(device);
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _busy = false; });
    }
  }

  Future<void> _requestHost(
    PairingCandidate host, {
    bool enterHostCode = false,
  }) async {
    final service = widget.discoveryService;
    if (_busy || service == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _attempt = null;
    });
    try {
      final exchange = await service.request(host);
      if (!mounted) return;
      if (exchange.registration != null) {
        await widget.onPaired(exchange.registration!.device);
        return;
      }
      if (enterHostCode) {
        final enteredCode = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _PairingCodeDialog(hostName: host.displayName),
        );
        if (!mounted) return;
        if (enteredCode == null) {
          setState(() => _busy = false);
          return;
        }
        if (enteredCode != exchange.attempt.confirmationCode) {
          setState(() {
            _busy = false;
            _error = '配对口令不匹配，请核对 Host 上显示的 6 位数字。';
          });
          return;
        }
      }
      setState(() => _attempt = exchange.attempt);
      _schedulePairingPoll();
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _busy = false; });
    }
  }

  Future<void> _openManualPairing(
    List<PairingCandidate> discoveredHosts,
  ) async {
    if (_busy) return;
    final method = await showModalBottomSheet<_ManualPairingMethod>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const _ManualPairingSheet(),
    );
    if (!mounted || method == null) return;
    switch (method) {
      case _ManualPairingMethod.scanQr:
        final payload = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (context) => const _QrScannerScreen()),
        );
        if (mounted && payload != null) await _pair(payload);
      case _ManualPairingMethod.pasteQr:
        final payload = await showDialog<String>(
          context: context,
          builder: (context) => const _QrPayloadDialog(),
        );
        if (mounted && payload != null) await _pair(payload);
      case _ManualPairingMethod.enterCode:
        if (discoveredHosts.isEmpty) {
          setState(() {
            _error = '填写口令前需要先发现 Host，请确认两台设备位于同一局域网后刷新。';
          });
          return;
        }
        final host = await showModalBottomSheet<PairingCandidate>(
          context: context,
          showDragHandle: true,
          builder: (context) => _PasscodeHostPicker(hosts: discoveredHosts),
        );
        if (mounted && host != null) {
          await _requestHost(host, enterHostCode: true);
        }
    }
  }

  Future<void> _refreshDiscovery() async {
    final refresh = widget.onRefreshDiscovery;
    if (_refreshing || refresh == null) return;
    setState(() {
      _refreshing = true;
      _error = null;
      _hosts.clear();
    });
    try {
      await refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '刷新失败：$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _schedulePairingPoll() {
    _pairingPoll?.cancel();
    _pairingPoll = Timer(const Duration(seconds: 1), _pollPairingRequest);
  }

  Future<void> _pollPairingRequest() async {
    final attempt = _attempt;
    final service = widget.discoveryService;
    if (!mounted || attempt == null || service == null) return;
    try {
      final exchange = await service.refresh(attempt);
      if (!mounted) return;
      setState(() => _attempt = exchange.attempt);
      if (exchange.registration != null) {
        await widget.onPaired(exchange.registration!.device);
        return;
      }
      if (exchange.attempt.state == PairingRequestState.pending &&
          exchange.attempt.localPollDeadline.isAfter(DateTime.now().toUtc())) {
        _schedulePairingPoll();
      } else {
        setState(() {
          _busy = false;
          _error = exchange.attempt.state == PairingRequestState.rejected
              ? 'Host 已拒绝配对请求。'
              : '配对请求已过期。';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
      _schedulePairingPoll();
    }
  }

  @override
  void dispose() {
    for (final session in _listenedSessions) {
      session.removeListener(_sessionChanged);
    }
    _listenedSessions.clear();
    _pairingPoll?.cancel();
    unawaited(_hostSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connectedDeviceIds = widget.connectedSessions
        .map((session) => session.device.deviceId)
        .toSet();
    final discoveredHosts = _hosts.values
        .where((host) => !connectedDeviceIds.contains(host.deviceId))
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: const Text('配对 CodePet Host')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
      if (_attempt != null) ...[
        Card(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              const Text('请在 Host 上确认以下配对码'),
              const SizedBox(height: 8),
              Text(
                _attempt!.confirmationCode,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(_attempt!.candidate.displayName),
            ]),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 8),
      Text(
        '已连接设备',
        key: const Key('connected-devices-title'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 10),
      _ConnectedDevicesTable(sessions: widget.connectedSessions),
      const SizedBox(height: 28),
      const Divider(),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: Text(
              '发现的设备',
              key: const Key('discovered-devices-title'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const Key('refresh-discovered-devices'),
            tooltip: '刷新局域网设备',
            onPressed: widget.onRefreshDiscovery == null || _refreshing
                ? null
                : _refreshDiscovery,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      Text(
        '同一局域网内的 Host 会自动出现在这里',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 8),
      if (discoveredHosts.isEmpty)
        const _EmptyDiscovery()
      else
        for (final host in discoveredHosts)
          Card(
            child: ListTile(
              leading: const Icon(Icons.computer_outlined),
              title: Text(host.displayName),
              subtitle: Text(host.hostInitiated
                  ? 'Host 正在请求配对'
                  : '${host.host}:${host.port}'),
              trailing: FilledButton(
                onPressed: _busy ? null : () => _requestHost(host),
                child: const Text('连接'),
              ),
            ),
          ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        key: const Key('manual-add-device'),
        onPressed: _busy ? null : () => _openManualPairing(discoveredHosts),
        icon: const Icon(Icons.add_link),
        label: const Text('手动添加设备'),
      ),
      const SizedBox(height: 6),
      Text(
        '扫码、粘贴二维码内容或输入 Host 配对口令',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      const SizedBox(height: 24),
    ]),
    );
  }
}

enum _ManualPairingMethod { scanQr, pasteQr, enterCode }

class _ManualPairingSheet extends StatelessWidget {
  const _ManualPairingSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('手动添加设备', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('选择一种配对方式。相机只会在扫码页面中启用。'),
              const SizedBox(height: 12),
              ListTile(
                key: const Key('manual-scan-qr'),
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('扫描二维码'),
                subtitle: const Text('扫描 Host 显示的 LAN 配对二维码'),
                onTap: () => Navigator.pop(context, _ManualPairingMethod.scanQr),
              ),
              ListTile(
                key: const Key('manual-paste-qr'),
                leading: const Icon(Icons.content_paste),
                title: const Text('粘贴二维码内容'),
                subtitle: const Text('适用于已复制的完整配对 JSON'),
                onTap: () => Navigator.pop(context, _ManualPairingMethod.pasteQr),
              ),
              ListTile(
                key: const Key('manual-enter-code'),
                leading: const Icon(Icons.password),
                title: const Text('填写配对口令'),
                subtitle: const Text('选择发现到的 Host，再输入其显示的 6 位数字'),
                onTap: () => Navigator.pop(context, _ManualPairingMethod.enterCode),
              ),
            ],
          ),
        ),
      );
}

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _resolved = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描配对二维码')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('将 Host 显示的 LAN 配对二维码放入取景框'),
                const SizedBox(height: 16),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(
                      key: const Key('manual-qr-scanner'),
                      controller: _scanner,
                      onDetect: (capture) {
                        final value = capture.barcodes.firstOrNull?.rawValue;
                        if (_resolved || value == null) return;
                        _resolved = true;
                        Navigator.pop(context, value);
                      },
                      errorBuilder: (context, error) => Center(
                        child: Text(
                          '无法使用相机：$error',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _QrPayloadDialog extends StatefulWidget {
  const _QrPayloadDialog();

  @override
  State<_QrPayloadDialog> createState() => _QrPayloadDialogState();
}

class _QrPayloadDialogState extends State<_QrPayloadDialog> {
  final TextEditingController _payload = TextEditingController();

  @override
  void dispose() {
    _payload.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('粘贴二维码内容'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('内容仍会经过证书 pin、身份和 endpoint 校验。'),
              const SizedBox(height: 12),
              TextField(
                key: const Key('qr-json-field'),
                controller: _payload,
                minLines: 4,
                maxLines: 8,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: '{"version":1,...}',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('pair-json-button'),
            onPressed: () {
              final value = _payload.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('验证并配对'),
          ),
        ],
      );
}

class _PasscodeHostPicker extends StatelessWidget {
  const _PasscodeHostPicker({required this.hosts});

  final List<PairingCandidate> hosts;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择 Host', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('选择后，Host 会弹出本次配对使用的 6 位口令。'),
              const SizedBox(height: 12),
              for (final host in hosts)
                ListTile(
                  key: Key('manual-passcode-host-${host.deviceId}'),
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(host.displayName),
                  subtitle: Text('${host.host}:${host.port}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, host),
                ),
            ],
          ),
        ),
      );
}

class _PairingCodeDialog extends StatefulWidget {
  const _PairingCodeDialog({required this.hostName});

  final String hostName;

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('填写配对口令'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('请输入 ${widget.hostName} 上显示的 6 位数字。'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pairing-code-field'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '配对口令',
                hintText: '000000',
                border: OutlineInputBorder(),
              ),
            ),
            const Text('输入后仍需在 Host 上确认接受。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-pairing-code'),
            onPressed: () {
              final value = _code.text;
              if (value.length == 6) Navigator.pop(context, value);
            },
            child: const Text('确认'),
          ),
        ],
      );
}

class _ConnectedDevicesTable extends StatelessWidget {
  const _ConnectedDevicesTable({required this.sessions});

  final List<DeviceSession> sessions;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: const _DeviceTableRow(
                name: '名称',
                system: '系统',
                status: '在线状态',
                header: true,
              ),
            ),
            if (sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: Text('暂无已连接设备'),
              )
            else
              for (var index = 0; index < sessions.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: _DeviceTableRow.fromSession(sessions[index]),
                ),
              ],
          ],
        ),
      );
}

class _DeviceTableRow extends StatelessWidget {
  const _DeviceTableRow({
    required this.name,
    required this.system,
    required this.status,
    this.header = false,
    this.connectionState,
  });

  factory _DeviceTableRow.fromSession(DeviceSession session) {
    final descriptor = session.device.descriptor;
    final system = descriptor == null
        ? '未知'
        : '${descriptor.operatingSystem} ${descriptor.systemVersion}'.trim();
    return _DeviceTableRow(
      name: session.device.effectiveName,
      system: system,
      status: _connectionLabel(session.connectionState),
      connectionState: session.connectionState,
    );
  }

  final String name;
  final String system;
  final String status;
  final bool header;
  final DeviceConnectionState? connectionState;

  @override
  Widget build(BuildContext context) {
    final style = header
        ? Theme.of(context).textTheme.labelMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Expanded(flex: 5, child: _TableText(name, style: style)),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: _TableText(system, style: style)),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: header
              ? _TableText(status, style: style)
              : _ConnectionStatus(
                  label: status,
                  state: connectionState!,
                ),
        ),
      ],
    );
  }
}

class _TableText extends StatelessWidget {
  const _TableText(this.value, {this.style});

  final String value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.label, required this.state});

  final String label;
  final DeviceConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      DeviceConnectionState.online => Colors.green.shade700,
      DeviceConnectionState.connecting => colorScheme.primary,
      DeviceConnectionState.failed => colorScheme.error,
      DeviceConnectionState.offline => colorScheme.outline,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 9, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }
}

class _EmptyDiscovery extends StatelessWidget {
  const _EmptyDiscovery();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            Icon(
              Icons.radar,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              '暂未发现可配对设备',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '请确认 Host 与此设备位于同一局域网',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
}

String _connectionLabel(DeviceConnectionState state) => switch (state) {
      DeviceConnectionState.online => '在线',
      DeviceConnectionState.connecting => '连接中',
      DeviceConnectionState.failed => '连接失败',
      DeviceConnectionState.offline => '离线',
    };
