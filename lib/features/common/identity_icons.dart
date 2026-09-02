import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

IconData providerIconData(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('codex')) return Icons.terminal;
  if (normalized.contains('claude')) return Icons.auto_awesome_outlined;
  if (normalized.contains('opencode')) return Icons.code;
  return Icons.extension_outlined;
}

Uri? providerIconUri(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

class ProviderIcon extends StatelessWidget {
  const ProviderIcon({
    super.key,
    required this.icon,
    required this.providerIdentity,
    this.size = 24,
    this.color,
    this.semanticLabel,
    this.imageProvider,
  });

  final String? icon;
  final String providerIdentity;
  final double size;
  final Color? color;
  final String? semanticLabel;

  /// Allows deterministic image decoding in widget tests. Production callers
  /// leave this unset so [CachedNetworkImage] owns downloading and caching.
  final ImageProvider<Object>? imageProvider;

  @override
  Widget build(BuildContext context) {
    final uri = providerIconUri(icon);
    final fallbackIdentity = uri == null && icon?.trim().isNotEmpty == true
        ? icon!
        : providerIdentity;
    final fallback = Icon(
      providerIconData(fallbackIdentity),
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
    if (uri == null) return fallback;
    if (imageProvider != null) {
      return SizedBox.square(
        dimension: size,
        child: Image(
          image: imageProvider!,
          width: size,
          height: size,
          fit: BoxFit.contain,
          semanticLabel: semanticLabel,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: CachedNetworkImage(
        imageUrl: uri.toString(),
        width: size,
        height: size,
        fit: BoxFit.contain,
        imageBuilder: (_, provider) => Image(
          image: provider,
          width: size,
          height: size,
          fit: BoxFit.contain,
          semanticLabel: semanticLabel,
        ),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

IconData operatingSystemIconData(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('mac') || normalized.contains('darwin')) {
    return Icons.apple;
  }
  if (normalized.contains('windows')) return Icons.window;
  if (normalized.contains('android')) return Icons.android;
  if (normalized.contains('ios') ||
      normalized.contains('iphone') ||
      normalized.contains('ipad')) {
    return Icons.phone_iphone;
  }
  if (normalized.contains('linux')) return Icons.terminal;
  return Icons.computer_outlined;
}
