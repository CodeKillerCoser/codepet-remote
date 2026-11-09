import '../../ui/layout/app_layout.dart';
import '../../ui/layout/app_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/ports/application_log.dart';
import '../../core/domain/notification.dart';
import 'signaling_service_settings.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    required this.exportLogs,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.logger = const NoopApplicationLog(),
    this.webRtcEnabled = false,
    this.activeWebRtcEnabled = false,
    this.onWebRtcChanged,
    this.notificationPreferences,
    this.onNotificationsChanged,
    this.notificationsAllowed,
    this.openNotificationSettings,
    this.signalingService,
    this.onSignalingServiceChanged,
  });

  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode)? onThemeModeChanged;

  final NotificationPreferences? notificationPreferences;
  final Future<NotificationPreferences> Function(NotificationPreferences)? onNotificationsChanged;
  final Future<bool> Function()? notificationsAllowed;
  final Future<void> Function()? openNotificationSettings;
  final String? signalingService;
  final Future<void> Function(String?)? onSignalingServiceChanged;
  final Future<String> Function() exportLogs;
  final ApplicationLog logger;
  final bool webRtcEnabled;
  final bool activeWebRtcEnabled;
  final Future<void> Function(bool enabled)? onWebRtcChanged;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> with WidgetsBindingObserver {
  late ThemeMode _themeMode = widget.themeMode;
  bool _savingTheme = false;
  Future<void> _changeTheme(ThemeMode mode) async {
    if (_savingTheme || widget.onThemeModeChanged == null) return;
    setState(() => _savingTheme = true);
    try {
      await widget.onThemeModeChanged!(mode);
      if (mounted) setState(() => _themeMode = mode);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('主题设置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _savingTheme = false);
    }
  }

  late NotificationPreferences? _notifications = widget.notificationPreferences;
  bool _savingNotifications = false;
  bool? _notificationsAllowed;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }
  Future<void> _refreshPermission() async {
    final allowed = await widget.notificationsAllowed?.call();
    if (mounted) setState(() => _notificationsAllowed = allowed);
  }
  Future<void> _changeNotifications(NotificationPreferences value) async {
    if (_savingNotifications || widget.onNotificationsChanged == null) return;
    setState(() => _savingNotifications = true);
    try {
      final saved = await widget.onNotificationsChanged!(value);
      if (mounted) setState(() => _notifications = saved);
      await _refreshPermission();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('无法开启，请检查系统通知权限后重试'),
        ));
      }
    } finally {
      if (mounted) setState(() => _savingNotifications = false);
    }
  }
  bool _exporting = false;
  bool _sharing = false;
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
    if (_exporting || _sharing) return;
    setState(() => _exporting = true);
    try {
      final path = await widget.exportLogs();
      if (!mounted) return;
      setState(() => _exportPath = path);
      // Open the chooser immediately: an action appended below this tile may
      // be outside the viewport after the archive path makes the tile taller.
      await _share();
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
    if (path == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      final renderBox = context.findRenderObject() as RenderBox?;
      widget.logger.info('Diagnostics share sheet requested');
      final result = await SharePlus.instance.share(
        ShareParams(
          subject: 'CodePet Remote 诊断日志',
          text: 'CodePet Remote 诊断日志压缩包',
          files: [XFile(path, mimeType: 'application/zip')],
          sharePositionOrigin: renderBox == null
              ? null
              : renderBox.localToGlobal(Offset.zero) & renderBox.size,
        ),
      );
      widget.logger.info('Diagnostics share sheet result: ${result.status.name}');
    } catch (error) {
      widget.logger.warning('Diagnostics share sheet failed', error: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('日志已导出，但无法打开系统分享，请点击分享按钮重试')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppScaffold(
    appBar: AppBar(title: const Text('App 设置')),
    body: ListView(
      padding: EdgeInsets.all(AppLayout.pageInset(context)),
      children: [
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('主题'),
          trailing: DropdownButton<ThemeMode>(
            key: const Key('theme-mode-selector'),
            value: _themeMode,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
            ],
            onChanged: _savingTheme || widget.onThemeModeChanged == null
              ? null : (mode) { if (mode != null) _changeTheme(mode); },
          ),
        ),
        const Divider(),
        if (_notifications case final preferences?) ...[
          const ListTile(leading: Icon(Icons.notifications_outlined), title: Text('通知')),
          if (_notificationsAllowed == false)
            ListTile(title: const Text('系统通知未开启'),
              subtitle: const Text('允许系统通知后才能接收任务提醒'),
              trailing: TextButton(onPressed: widget.openNotificationSettings,
                child: const Text('去设置'))),
          SwitchListTile(key: const Key('notification-outcomes'), title: const Text('任务结果'),
            subtitle: const Text('任务完成或失败时提醒，主动停止不提醒'),
            value: preferences.outcomes, onChanged: _savingNotifications ? null
              : (value) => _changeNotifications(preferences.copyWith(outcomes: value))),
          SwitchListTile(key: const Key('notification-interventions'), title: const Text('需要你处理'),
            subtitle: const Text('等待授权或补充信息时提醒'),
            value: preferences.interventions, onChanged: _savingNotifications ? null
              : (value) => _changeNotifications(preferences.copyWith(interventions: value))),
          SwitchListTile(key: const Key('notification-preview'), title: const Text('显示内容预览'),
            subtitle: const Text('在通知中显示会话标题和简短说明，锁屏遵循系统隐私设置'),
            value: preferences.preview, onChanged: _savingNotifications ? null
              : (value) => _changeNotifications(preferences.copyWith(preview: value))),
          SwitchListTile(key: const Key('background-connection'), title: const Text('后台保持连接'),
            subtitle: const Text('显示常驻连接通知，切换 App 后继续接收事件。深度省电、强行停止或网络中断仍可能导致断线；后台提醒需要连接可用。'),
            value: preferences.keepConnected, onChanged: _savingNotifications ? null
              : (value) => _changeNotifications(preferences.copyWith(keepConnected: value))),
          if (!preferences.keepConnected && (preferences.outcomes || preferences.interventions))
            const ListTile(subtitle: Text('当前仅在 App 能接收设备事件时提醒。建议同时开启后台保持连接。')),
          const Divider(),
        ],
        SwitchListTile(
          key: const Key('webrtc-switch'),
          title: const Text('开启 WebRTC'),
          subtitle: const Text('更改后完全退出并重新打开 App 生效。首次公网授权需在同一局域网连接新版电脑端。'),
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
        if (widget.onSignalingServiceChanged case final save?) ...[
          SignalingServiceSettings(
            value: widget.signalingService,
            onSave: save,
          ),
          const Divider(),
        ],
        const ListTile(
          leading: Icon(Icons.security),
          title: Text('Gateway v1'),
          subtitle: Text('设备凭据保存在 Android Keystore 支持的安全存储中；会话正文和事件游标不落盘，通知去重只保存路由标识和处理状态。'),
        ),
        const Divider(),
        ListTile(
          key: const Key('export-logs'),
          leading: const Icon(Icons.folder_zip_outlined),
          title: const Text('导出并分享诊断日志'),
          subtitle: Text(
            _exportPath ?? '日志保留 7 天，单文件 2 MB，最多 5 个文件',
            key: const Key('export-log-path'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _exporting || _sharing
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _exportPath == null
                  ? const Icon(Icons.share_outlined)
                  : IconButton(
                      key: const Key('share-logs'),
                      tooltip: '再次分享日志',
                      onPressed: _share,
                      icon: const Icon(Icons.share_outlined),
                    ),
          onTap: _exporting || _sharing ? null : _export,
        ),
      ],
    ),
  );
}
