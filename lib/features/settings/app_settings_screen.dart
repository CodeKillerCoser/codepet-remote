import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/ports/application_log.dart';
import '../../application/sessions/device_session.dart';
import '../../core/domain/paired_device.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    required this.sessions,
    required this.onForgetDevice,
    required this.exportLogs,
    this.logger = const NoopApplicationLog(),
    this.webRtcEnabled = false,
    this.activeWebRtcEnabled = false,
    this.onWebRtcChanged,
  });

  final List<DeviceSession> sessions;
  final Future<void> Function(DeviceSession session) onForgetDevice;
  final Future<String> Function() exportLogs;
  final ApplicationLog logger;
  final bool webRtcEnabled;
  final bool activeWebRtcEnabled;
  final Future<void> Function(bool enabled)? onWebRtcChanged;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _exporting = false;
  String? _exportPath;
  late bool _webRtcEnabled = widget.webRtcEnabled;
  bool _savingChannel = false;

  Future<void> _changeChannel(bool enabled) async {
    setState(() => _savingChannel = true);
    try {
      await widget.onWebRtcChanged!(enabled);
      if (!mounted) return;
      setState(() => _webRtcEnabled = enabled);
    } catch (error) {
      widget.logger.warning('Channel preference save failed', error: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    } finally {
      if (mounted) setState(() => _savingChannel = false);
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final path = await widget.exportLogs();
      if (!mounted) return;
      setState(() => _exportPath = path);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('日志压缩包已生成')));
    } catch (error) {
      widget.logger.warning(
        'Diagnostics export failed from settings',
        error: error,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('日志导出失败：$error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share() async {
    final path = _exportPath;
    if (path == null) return;
    try {
      final renderBox = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          subject: 'CodePet Remote 诊断日志',
          text: 'CodePet Remote 诊断日志压缩包',
          files: [XFile(path, mimeType: 'application/zip')],
          sharePositionOrigin: renderBox == null
              ? null
              : renderBox.localToGlobal(Offset.zero) & renderBox.size,
        ),
      );
    } catch (error) {
      widget.logger.warning('Diagnostics share sheet failed', error: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法打开系统分享：$error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('App 设置')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          key: const Key('webrtc-switch'),
          title: const Text('开启 WebRTC'),
          subtitle: const Text('更改后完全退出并重新打开 App 生效。当前仍需与电脑处于同一局域网。'),
          value: _webRtcEnabled,
          onChanged: _savingChannel || widget.onWebRtcChanged == null
              ? null
              : _changeChannel,
        ),
        ListTile(
          title: Text(
            '当前通道：${widget.activeWebRtcEnabled ? 'WebRTC' : 'LAN / WSS'}',
          ),
          subtitle: _webRtcEnabled != widget.activeWebRtcEnabled
              ? const Text('设置已保存，重启 App 后生效')
              : null,
        ),
        const Divider(),
        const ListTile(
          leading: Icon(Icons.security),
          title: Text('Gateway v1'),
          subtitle: Text('设备凭据保存在 Android Keystore 支持的安全存储中；会话和事件游标不落盘。'),
        ),
        const Divider(),
        ListTile(
          key: const Key('export-logs'),
          leading: const Icon(Icons.folder_zip_outlined),
          title: const Text('导出诊断日志'),
          subtitle: Text(
            _exportPath ?? '日志保留 7 天，单文件 2 MB，最多 5 个文件',
            key: const Key('export-log-path'),
          ),
          trailing: _exporting
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _exporting ? null : _export,
        ),
        if (_exportPath != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('share-logs'),
              onPressed: _share,
              icon: const Icon(Icons.share_outlined),
              label: const Text('分享到微信、钉钉或其他 App'),
            ),
          ),
        const Divider(),
        for (final session in widget.sessions.where(
          (item) =>
              item.device.connectionKind == DeviceConnectionKind.pairedGateway,
        ))
          ListTile(
            title: Text(session.device.effectiveName),
            subtitle: Text(session.device.deviceId),
            trailing: TextButton(
              child: const Text('忘记'),
              onPressed: () => widget.onForgetDevice(session),
            ),
          ),
      ],
    ),
  );
}
