import '../../ui/layout/app_layout.dart';
import '../../ui/theme/app_semantics.dart';

import 'package:flutter/material.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/signaling_service.dart';

class SignalingServiceSettings extends StatefulWidget {
  const SignalingServiceSettings({
    super.key,
    this.value,
    this.showHeading = true,
    required this.onSave,
  });
  final String? value;
  final bool showHeading;
  final Future<void> Function(String?) onSave;

  @override
  State<SignalingServiceSettings> createState() =>
      _SignalingServiceSettingsState();
}

class _SignalingServiceSettingsState extends State<SignalingServiceSettings> {
  late final _controller = TextEditingController(text: widget.value ?? '');
  bool _saving = false, _saved = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      final address = normalizeSignalingService(_controller.text);
      await widget.onSave(address);
      if (!mounted) return;
      _controller.text = address ?? '';
      setState(() => _saved = true);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on SignalingRegistrationException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.showHeading) ...[
        Text('信令服务', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppLayout.space12),
      ],
      TextField(
        key: const Key('signaling-service-address'),
        controller: _controller,
        enabled: !_saving,
        autocorrect: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) => setState(() {
          _saved = false;
          _error = null;
        }),
        decoration: const InputDecoration(
          labelText: '服务器地址',
          hintText: 'IP 或域名',
        ),
      ),
      const SizedBox(height: AppLayout.space16),
      Text(
        '填写 IP 或域名即可自动登记，默认 HTTPS、8443 端口；也可填写完整 HTTPS 地址。留空使用配对提供的地址。已有连接在下次重连时切换；更换服务后需重新连接或配对电脑。',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: AppLayout.sectionGap),
      FilledButton(
        key: const Key('save-signaling-service'),
        onPressed: _saving ? null : _save,
        child: Text(_saving ? '登记中…' : '保存并登记'),
      ),
      if (_saved)
        Padding(
          padding: const EdgeInsets.only(top: AppLayout.space12),
          child: Text(
            _controller.text.isEmpty ? '已恢复配对提供的服务地址' : '设备已登记，可开始配对',
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: AppLayout.space12),
          child: Text(_error!, style: Theme.of(context).errorText),
        ),
    ],
  );
}
