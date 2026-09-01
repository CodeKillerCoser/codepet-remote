import 'package:flutter/material.dart';

import '../../gateway/models.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({
    super.key,
    required this.onConnect,
    required this.onOpenDemo,
  });

  final Future<void> Function(DeviceConnection connection) onConnect;
  final Future<void> Function() onOpenDemo;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _deviceController = TextEditingController(text: '我的电脑');
  final _uriController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _isConnecting = false;
  bool _obscureToken = true;
  String? _error;

  @override
  void dispose() {
    _deviceController.dispose();
    _uriController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final connection = DeviceConnection(
      deviceName: _deviceController.text.trim(),
      gatewayUri: Uri.parse(_uriController.text.trim()),
      pairingToken: _tokenController.text.trim(),
    );
    await _run(() => widget.onConnect(connection));
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _isConnecting = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '请填写此项';
    }
    return null;
  }

  String? _validateGatewayUri(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '请输入 Gateway 地址';
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
      return '请输入完整的 wss:// 地址';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('开发连接')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(
                          Icons.pets_outlined,
                          color: colorScheme.onPrimaryContainer,
                          size: 34,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '手动连接 Gateway',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '这是 Gateway v2 的手动通道入口。请只连接你信任的 Host；令牌仅用于本次运行时连接。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      key: const Key('device-name-field'),
                      controller: _deviceController,
                      enabled: !_isConnecting,
                      decoration: const InputDecoration(
                        labelText: '设备名称',
                        hintText: '例如：办公室 Mac',
                        prefixIcon: Icon(Icons.computer_outlined),
                      ),
                      validator: _validateRequired,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('gateway-uri-field'),
                      controller: _uriController,
                      enabled: !_isConnecting,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Gateway 地址',
                        hintText: 'wss://192.168.1.20:端口/gateway',
                        prefixIcon: Icon(Icons.lan_outlined),
                      ),
                      validator: _validateGatewayUri,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('pairing-token-field'),
                      controller: _tokenController,
                      enabled: !_isConnecting,
                      obscureText: _obscureToken,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: '配对令牌',
                        prefixIcon: const Icon(Icons.key_outlined),
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() {
                              _obscureToken = !_obscureToken;
                            });
                          },
                          icon: Icon(
                            _obscureToken
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validateRequired,
                      onFieldSubmitted: (_) => _connect(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const Key('connect-button'),
                      onPressed: _isConnecting ? null : _connect,
                      icon: _isConnecting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(_isConnecting ? '正在连接…' : '添加并连接'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('demo-button'),
                      onPressed: _isConnecting
                          ? null
                          : () => _run(widget.onOpenDemo),
                      child: const Text('添加演示设备'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '当前真实连接要求 Host 提供受信任的 TLS 证书与 Bearer 配对令牌。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
