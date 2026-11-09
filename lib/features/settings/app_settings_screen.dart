import '../../ui/components/app_switch_tile.dart';
import '../../ui/components/app_settings_section.dart';
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
  final Future<NotificationPreferences> Function(NotificationPreferences)?
  onNotificationsChanged;
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

class _AppSettingsScreenState extends State<AppSettingsScreen>
    with WidgetsBindingObserver {
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('主题设置保存失败，请重试')));
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法开启，请检查系统通知权限后重试')));
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
      widget.logger.info(
        'Diagnostics share sheet result: ${result.status.name}',
      );
    } catch (error) {
      widget.logger.warning('Diagnostics share sheet failed', error: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已导出，但无法打开系统分享，请点击分享按钮重试')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  late String? _signalingService = widget.signalingService;

  String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  Future<void> _chooseTheme() async {
    final choice = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: AppLayout.selectionSheetPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in ThemeMode.values)
                ListTile(
                  key: Key('theme-option-${mode.name}'),
                  title: Text(_themeLabel(mode)),
                  trailing: mode == _themeMode ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(context).pop(mode),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && mounted) await _changeTheme(choice);
  }

  void _openSignalingService() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AppScaffold(
          appBar: AppBar(title: const Text('信令服务')),
          body: ListView(
            padding: EdgeInsets.all(AppLayout.pageInset(context)),
            children: [
              SignalingServiceSettings(
                value: _signalingService,
                showHeading: false,
                onSave: (value) async {
                  await widget.onSignalingServiceChanged!(value);
                  if (mounted) setState(() => _signalingService = value);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _notifications;
    final canChangeNotifications =
        !_savingNotifications && widget.onNotificationsChanged != null;
    return AppScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('settings-list'),
          padding: EdgeInsets.all(AppLayout.pageInset(context)),
          children: [
            AppSettingsSection(
              title: '外观',
              children: [
                ListTile(
                  key: const Key('theme-mode-selector'),
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('主题'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _themeLabel(_themeMode),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: AppLayout.gap),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: _savingTheme || widget.onThemeModeChanged == null
                      ? null
                      : _chooseTheme,
                ),
              ],
            ),
            if (preferences != null)
              AppSettingsSection(
                title: '通知',
                children: [
                  if (_notificationsAllowed == false)
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('系统通知未开启'),
                      trailing: TextButton(
                        onPressed: widget.openNotificationSettings,
                        child: const Text('去开启'),
                      ),
                    ),
                  AppSwitchTile(
                    key: const Key('notification-outcomes'),
                    title: const Text('任务结果'),
                    subtitle: const Text('任务完成或失败时提醒'),
                    value: preferences.outcomes,
                    onChanged: !canChangeNotifications
                        ? null
                        : (value) => _changeNotifications(
                            preferences.copyWith(outcomes: value),
                          ),
                  ),
                  AppSwitchTile(
                    key: const Key('notification-interventions'),
                    title: const Text('需要你处理'),
                    subtitle: const Text('等待授权或补充信息时提醒'),
                    value: preferences.interventions,
                    onChanged: !canChangeNotifications
                        ? null
                        : (value) => _changeNotifications(
                            preferences.copyWith(interventions: value),
                          ),
                  ),
                  AppSwitchTile(
                    key: const Key('notification-preview'),
                    title: const Text('内容预览'),
                    subtitle: const Text('在通知中显示会话标题和摘要'),
                    value: preferences.preview,
                    onChanged: !canChangeNotifications
                        ? null
                        : (value) => _changeNotifications(
                            preferences.copyWith(preview: value),
                          ),
                  ),
                ],
              ),
            AppSettingsSection(
              title: '连接与后台',
              children: [
                if (preferences != null)
                  AppSwitchTile(
                    key: const Key('background-connection'),
                    title: const Text('后台保持连接'),
                    subtitle: const Text('切换 App 后继续接收任务消息'),
                    value: preferences.keepConnected,
                    onChanged: !canChangeNotifications
                        ? null
                        : (value) => _changeNotifications(
                            preferences.copyWith(keepConnected: value),
                          ),
                  ),
                AppSwitchTile(
                  key: const Key('webrtc-switch'),
                  title: const Text('WebRTC'),
                  subtitle: Text(
                    _webRtcEnabled != widget.activeWebRtcEnabled
                        ? '设置已保存，重启 App 后生效'
                        : '允许设备间直接连接，更改后重启生效',
                  ),
                  value: _webRtcEnabled,
                  onChanged: _savingChannel || widget.onWebRtcChanged == null
                      ? null
                      : _changeChannel,
                ),
                if (widget.onSignalingServiceChanged != null)
                  ListTile(
                    key: const Key('signaling-service-entry'),
                    title: const Text('信令服务'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_signalingService == null)
                          Text(
                            '未配置',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        const SizedBox(width: AppLayout.gap),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    subtitle: _signalingService == null
                        ? null
                        : Text(
                            _signalingService!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: _openSignalingService,
                  ),
              ],
            ),
            AppSettingsSection(
              title: '诊断',
              children: [
                ListTile(
                  key: const Key('export-logs'),
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('导出日志'),
                  subtitle: Text(
                    _exportPath ?? '用于排查连接与消息问题',
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
                      ? const Icon(Icons.chevron_right)
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
          ],
        ),
      ),
    );
  }
}
