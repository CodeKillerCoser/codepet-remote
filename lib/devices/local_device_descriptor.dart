import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import '../gateway/models.dart';

abstract interface class DeviceDescriptorProvider {
  Future<DeviceDescriptor> load();
}

class LocalDeviceDescriptorProvider implements DeviceDescriptorProvider {
  LocalDeviceDescriptorProvider({DeviceInfoPlugin? deviceInfo})
      : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;
  Future<DeviceDescriptor>? _cached;

  @override
  Future<DeviceDescriptor> load() => _cached ??= _load();

  Future<DeviceDescriptor> _load() async {
    try {
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        final manufacturer = _value(info.manufacturer);
        final model = _value(info.model);
        final modelName = [
          if (manufacturer != null &&
              (model == null ||
                  !model.toLowerCase().startsWith(manufacturer.toLowerCase())))
            manufacturer,
          ?model,
        ].join(' ');
        return DeviceDescriptor(
          deviceName: _first([
            info.name,
            modelName,
            model,
            _localHostname(),
          ], 'Android device'),
          operatingSystem: 'Android',
          systemVersion: _first([
            info.version.release,
            'API ${info.version.sdkInt}',
            _operatingSystemVersion(),
          ], 'unknown'),
        );
      }
      if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        return DeviceDescriptor(
          deviceName: _first([
            info.name,
            info.modelName,
            info.localizedModel,
            info.utsname.machine,
          ], 'iOS device'),
          operatingSystem: _first([info.systemName], 'iOS'),
          systemVersion: _first([
            info.systemVersion,
            _operatingSystemVersion(),
          ], 'unknown'),
        );
      }
      if (Platform.isMacOS) {
        final info = await _deviceInfo.macOsInfo;
        final version = [
          info.majorVersion,
          info.minorVersion,
          info.patchVersion,
        ].join('.');
        return DeviceDescriptor(
          deviceName: _first([
            info.computerName,
            info.modelName,
            info.model,
            _localHostname(),
          ], 'Mac'),
          operatingSystem: 'macOS',
          systemVersion: _first([
            version,
            info.osRelease,
            _operatingSystemVersion(),
          ], 'unknown'),
        );
      }
      if (Platform.isWindows) {
        final info = await _deviceInfo.windowsInfo;
        final version =
            '${info.majorVersion}.${info.minorVersion}.${info.buildNumber}';
        return DeviceDescriptor(
          deviceName: _first([
            info.computerName,
            _localHostname(),
          ], 'Windows device'),
          operatingSystem: _first([info.productName], 'Windows'),
          systemVersion: _first([
            info.displayVersion,
            version,
            _operatingSystemVersion(),
          ], 'unknown'),
        );
      }
      if (Platform.isLinux) {
        final info = await _deviceInfo.linuxInfo;
        return DeviceDescriptor(
          deviceName: _first([_localHostname()], 'Linux device'),
          operatingSystem: _first([info.name], 'Linux'),
          systemVersion: _first([
            info.versionId,
            info.version,
            _operatingSystemVersion(),
          ], 'unknown'),
        );
      }
    } catch (_) {
      return fallbackDeviceDescriptor();
    }
    return fallbackDeviceDescriptor();
  }
}

DeviceDescriptor fallbackDeviceDescriptor() {
  final platform = switch (Platform.operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    final value => _first([value], 'Unknown OS'),
  };
  final mobile = Platform.isAndroid || Platform.isIOS;
  return DeviceDescriptor(
    deviceName: _first([
      if (!mobile) _localHostname(),
      '$platform device',
    ], 'CodePet Remote'),
    operatingSystem: platform,
    systemVersion:
        _first([_operatingSystemVersion()], 'unknown'),
  );
}

String? _value(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase() == 'unknown') return null;
  return trimmed;
}

String? _localHostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return null;
  }
}

String? _operatingSystemVersion() {
  try {
    return Platform.operatingSystemVersion;
  } catch (_) {
    return null;
  }
}

String _first(Iterable<String?> values, String fallback) {
  for (final value in values) {
    if (value == null) continue;
    final normalized = _value(value);
    if (normalized != null) return normalized;
  }
  return fallback;
}
