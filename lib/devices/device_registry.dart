import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/domain/models.dart';
import '../core/domain/paired_device.dart';
import '../application/ports/device_repository.dart';
import '../application/ports/application_log.dart';
import '../security/pinned_tls.dart';

abstract interface class CredentialStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore([this.storage = const FlutterSecureStorage(aOptions: AndroidOptions())]);
  final FlutterSecureStorage storage;
  @override Future<void> write(String key, String value) => storage.write(key: key, value: value);
  @override Future<String?> read(String key) => storage.read(key: key);
  @override Future<void> delete(String key) => storage.delete(key: key);
}

abstract interface class DeviceMetadataStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PreferencesMetadataStore implements DeviceMetadataStore {
  @override Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);
  @override Future<void> write(String key, String value) async { await (await SharedPreferences.getInstance()).setString(key, value); }
}

class DeviceRegistry implements DeviceRepository {
  DeviceRegistry({
    required this.metadata,
    required this.credentials,
    this.logger = const NoopApplicationLog(),
  });
  static const devicesKey = 'paired_devices_v1';
  static const clientIdKey = 'remote_installation_client_id_v1';
  final DeviceMetadataStore metadata;
  final CredentialStore credentials;
  final ApplicationLog logger;
  Future<void> _metadataMutation = Future<void>.value();

  Future<T> _mutate<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _metadataMutation = _metadataMutation.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  Future<String> loadOrCreateClientId() => _mutate(() async {
        final existing = await metadata.read(clientIdKey);
        if (existing != null && existing.isNotEmpty) return existing;
        final random = Random.secure();
        final bytes = List<int>.generate(24, (_) => random.nextInt(256));
        final value = 'remote-${base64Url.encode(bytes).replaceAll('=', '')}';
        await metadata.write(clientIdKey, value);
        logger.info('Created a new local installation identity');
        return value;
      });

  @override
  Future<List<PairedDevice>> load() async {
    try {
      final source = await metadata.read(devicesKey);
      if (source == null) return [];
      final decoded = jsonDecode(source);
      if (decoded is! List) throw const FormatException('Invalid paired device registry');
      return decoded.map((item) => PairedDevice.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    } catch (error, stackTrace) {
      logger.warning(
        'Paired device registry load failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _writeDevices(List<PairedDevice> devices) => metadata.write(
        devicesKey,
        jsonEncode(devices.map((device) => device.toJson()).toList()),
      );

  Future<void> save(List<PairedDevice> devices) =>
      _mutate(() => _writeDevices(devices));

  @override
  Future<String?> readCredential(PairedDevice device) async {
    final key = device.credentialKeyRef;
    return key == null ? null : credentials.read(key);
  }

  @override
  Future<void> updatePreferredEndpoint({
    required String deviceId,
    required String clientId,
    required String tlsFingerprint,
    required String endpoint,
  }) {
    return _mutate(() async {
      final devices = await load();
      final index = devices.indexWhere((device) =>
          device.deviceId == deviceId &&
          device.clientId == clientId &&
          device.tlsFingerprint == tlsFingerprint);
      if (index == -1) {
        throw StateError('Endpoint does not match the paired identity');
      }
      if (devices[index].preferredEndpoint == endpoint) return;
      devices[index] = devices[index].withPreferredEndpoint(endpoint);
      await _writeDevices(devices);
      logger.fine('Persisted preferred endpoint for device $deviceId');
    });
  }

  @override
  Future<void> updateHostDescriptor({
    required String deviceId,
    required String clientId,
    required String tlsFingerprint,
    required DeviceDescriptor descriptor,
  }) {
    return _mutate(() async {
      final devices = await load();
      final index = devices.indexWhere((device) =>
          device.deviceId == deviceId &&
          device.clientId == clientId &&
          device.tlsFingerprint == tlsFingerprint);
      if (index == -1) {
        throw StateError('Host descriptor does not match the paired identity');
      }
      final current = devices[index].descriptor;
      if (current?.deviceName == descriptor.deviceName &&
          current?.operatingSystem == descriptor.operatingSystem &&
          current?.systemVersion == descriptor.systemVersion) {
        return;
      }
      devices[index] = devices[index].withDescriptor(descriptor);
      await _writeDevices(devices);
      logger.fine('Persisted Host descriptor for device $deviceId');
    });
  }

  @override
  Future<void> register(PairedDevice device, String credential) =>
      _mutate(() async {
    final key = device.credentialKeyRef;
    if (key == null) throw ArgumentError('credentialKeyRef is required');
    final previousCredential = await credentials.read(key);
    await credentials.write(key, credential);
    try {
      final devices = await load();
      devices.removeWhere((item) => item.deviceId == device.deviceId);
      devices.add(device);
      await _writeDevices(devices);
      logger.info('Persisted paired device ${device.deviceId}');
    } catch (error, stackTrace) {
      logger.warning(
        'Paired device persistence failed for device ${device.deviceId}; '
        'restoring previous credential state',
        error: error,
        stackTrace: stackTrace,
      );
      if (previousCredential == null) {
        await credentials.delete(key);
      } else {
        await credentials.write(key, previousCredential);
      }
      rethrow;
    }
  });

  @override
  Future<void> forget(PairedDevice device) async {
    logger.info('Device forget started for device ${device.deviceId}');
    String? credential;
    try {
      credential = await readCredential(device);
    } catch (error, stackTrace) {
      logger.warning(
        'Credential lookup during device forget failed for device '
        '${device.deviceId}',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      await _mutate(() async {
        final devices = await load();
        devices.removeWhere((item) => item.deviceId == device.deviceId);
        await _writeDevices(devices);
        final key = device.credentialKeyRef;
        if (key != null) {
          try {
            await credentials.delete(key);
          } catch (error, stackTrace) {
            logger.warning(
              'Local credential deletion failed for device '
              '${device.deviceId}',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      });
      logger.info('Device removed from local registry ${device.deviceId}');
    } catch (error, stackTrace) {
      logger.warning(
        'Device forget failed before local registry removal for device '
        '${device.deviceId}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    if (credential != null &&
        device.preferredEndpoint != null &&
        device.tlsFingerprint != null) {
      final gateway = Uri.parse(device.preferredEndpoint!);
      final revoke = gateway.replace(
        scheme: 'https',
        path: '/remote/v1/credentials/current',
        query: null,
      );
      try {
        await PinnedTlsConnection(
          expectedSha256: device.tlsFingerprint!,
        ).jsonRequest(method: 'DELETE', uri: revoke, bearer: credential);
        logger.info('Remote credential revoked for device ${device.deviceId}');
      } catch (error, stackTrace) {
        logger.warning(
          'Remote credential revocation failed for device ${device.deviceId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
