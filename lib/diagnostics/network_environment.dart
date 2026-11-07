import 'dart:io';

import 'package:flutter/services.dart';

/// Platform inspection stays here; callers never alter routing for diagnostics.
abstract interface class NetworkEnvironment {
  Future<Map<Object?, Object?>> snapshot();
}

final class SystemNetworkEnvironment implements NetworkEnvironment {
  const SystemNetworkEnvironment();
  static const _channel = MethodChannel(
    'com.codepet.remote/network_diagnostics',
  );

  @override
  Future<Map<Object?, Object?>> snapshot() async {
    if (Platform.isAndroid) {
      return await _channel.invokeMapMethod<Object?, Object?>('snapshot') ?? {};
    }
    final interfaces = await NetworkInterface.list(
      includeLoopback: true,
      includeLinkLocal: true,
    );
    return {
      'source': 'dartNetworkInterfaces',
      // Absence of platform metadata is unknown, never interpreted as no VPN.
      'networks': interfaces
          .take(32)
          .map(
            (interface) => {
              'interface': interface.name,
              'addresses': interface.addresses
                  .take(32)
                  .map(
                    (address) => {'address': address.address.split('%').first},
                  )
                  .toList(),
            },
          )
          .toList(),
      'truncated': interfaces.length > 32,
    };
  }
}
