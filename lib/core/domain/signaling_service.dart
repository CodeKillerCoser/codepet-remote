/// Public service location, kept separate from device keys and authorizations.
String? normalizeSignalingService(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  const message = '请输入 IP、域名或 HTTPS 地址；可指定端口，不支持路径、账号或查询参数';
  if (RegExp(r'\s').hasMatch(value) || value.contains(r'\')) {
    throw const FormatException(message);
  }
  final explicitScheme = value.contains('://');
  final bareIpv6 =
      !explicitScheme &&
      !value.startsWith('[') &&
      ':'.allMatches(value).length > 1;
  final uri = Uri.tryParse(
    explicitScheme
        ? value
        : bareIpv6
        ? 'https://[$value]:8443'
        : 'https://$value',
  );
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException(message);
  }
  final port =
      !explicitScheme &&
          !uri.hasPort &&
          !value.replaceFirst(RegExp(r'/$'), '').endsWith(':443')
      ? 8443
      : uri.port;
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: port == 443 ? null : port,
  ).toString();
}
