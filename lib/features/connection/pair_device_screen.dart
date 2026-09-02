import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../admission/lan_admission.dart';
import '../../devices/device_models.dart';

class PairDeviceScreen extends StatefulWidget {
  const PairDeviceScreen({super.key, required this.pairingService, required this.onPaired, this.onAddDemo});
  final LanAdmissionService pairingService;
  final Future<void> Function(PairedDevice device) onPaired;
  final Future<void> Function()? onAddDemo;
  @override State<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends State<PairDeviceScreen> {
  final MobileScannerController _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  final TextEditingController _payload = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _pair(String value) async {
    if (_busy || value.trim().isEmpty) return;
    setState(() { _busy = true; _error = null; });
    await _scanner.stop();
    try {
      final device = await widget.pairingService.pair(value.trim());
      await widget.onPaired(device);
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _busy = false; });
      await _scanner.start();
    }
  }

  @override void dispose() { _scanner.dispose(); _payload.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('配对 CodePet Host')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Text('扫描 Host 显示的 LAN 配对二维码', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      AspectRatio(
        aspectRatio: 1.35,
        child: ClipRRect(borderRadius: BorderRadius.circular(16), child: MobileScanner(
          controller: _scanner,
          onDetect: (capture) { final value = capture.barcodes.firstOrNull?.rawValue; if (value != null) _pair(value); },
          errorBuilder: (context, error) => Center(child: Text('无法使用相机：$error', textAlign: TextAlign.center)),
        )),
      ),
      const SizedBox(height: 16),
      ExpansionTile(
        title: const Text('开发诊断：粘贴 QR JSON'),
        subtitle: const Text('仍会执行证书 pin、身份和 endpoint 校验，不能绕过安全检查。'),
        children: [
          TextField(key: const Key('qr-json-field'), controller: _payload, minLines: 4, maxLines: 8, autocorrect: false, decoration: const InputDecoration(hintText: '{"version":1,...}')),
          const SizedBox(height: 12),
          FilledButton(key: const Key('pair-json-button'), onPressed: _busy ? null : () => _pair(_payload.text), child: Text(_busy ? '正在安全配对…' : '验证并配对')),
        ],
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 12),
      const Text('发现提示：QR endpoint 直连优先。mDNS 发现只提供候选 Host，不建立信任。', textAlign: TextAlign.center),
    ]),
  );
}
