import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/pinned_tls.dart';
import 'device_models.dart';

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

class DeviceRegistry {
  DeviceRegistry({required this.metadata, required this.credentials});
  static const devicesKey = 'paired_devices_v1';
  static const clientIdKey = 'remote_installation_client_id_v1';
  final DeviceMetadataStore metadata;
  final CredentialStore credentials;
  Future<void> _endpointMutation = Future<void>.value();

  Future<String> loadOrCreateClientId() async {
    final existing = await metadata.read(clientIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final value = 'remote-${base64Url.encode(bytes).replaceAll('=', '')}';
    await metadata.write(clientIdKey, value);
    return value;
  }

  Future<List<PairedDevice>> load() async {
    final source = await metadata.read(devicesKey);
    if (source == null) return [];
    final decoded = jsonDecode(source);
    if (decoded is! List) throw const FormatException('Invalid paired device registry');
    return decoded.map((item) => PairedDevice.fromJson(Map<String, dynamic>.from(item as Map))).toList();
  }

  Future<void> save(List<PairedDevice> devices) => metadata.write(devicesKey, jsonEncode(devices.map((device) => device.toJson()).toList()));

  Future<void> updatePreferredEndpoint(String deviceId, String endpoint) {
    final mutation = _endpointMutation.then((_) async {
      final devices = await load();
      final index = devices.indexWhere((device) => device.deviceId == deviceId);
      if (index == -1 || devices[index].preferredEndpoint == endpoint) return;
      devices[index] = devices[index].withPreferredEndpoint(endpoint);
      await save(devices);
    });
    _endpointMutation = mutation.catchError((_) {});
    return mutation;
  }

  Future<void> register(PairedDevice device, String credential) async {
    final key = device.credentialKeyRef;
    if (key == null) throw ArgumentError('credentialKeyRef is required');
    await credentials.write(key, credential);
    final devices = await load();
    devices.removeWhere((item) => item.deviceId == device.deviceId);
    devices.add(device);
    try { await save(devices); } catch (_) { await credentials.delete(key); rethrow; }
  }

  Future<void> forget(PairedDevice device) async {
    final credential = device.credentialKeyRef == null ? null : await credentials.read(device.credentialKeyRef!);
    if (credential != null && device.preferredEndpoint != null && device.tlsFingerprint != null) {
      final gateway = Uri.parse(device.preferredEndpoint!);
      final revoke = gateway.replace(scheme: 'https', path: '/remote/v1/credentials/current', query: null);
      try { await PinnedTlsConnection(expectedSha256: device.tlsFingerprint!).jsonRequest(method: 'DELETE', uri: revoke, bearer: credential); } catch (_) {}
    }
    if (device.credentialKeyRef != null) await credentials.delete(device.credentialKeyRef!);
    final devices = await load();
    devices.removeWhere((item) => item.deviceId == device.deviceId);
    await save(devices);
  }
}
