import '../../core/domain/paired_device.dart';
import '../../core/domain/models.dart';

abstract interface class DeviceRepository {
  Future<String> loadOrCreateClientId();
  Future<List<PairedDevice>> load();
  Future<String?> readCredential(PairedDevice device);
  Future<void> register(PairedDevice device, String credential);
  Future<void> forget(PairedDevice device);
  Future<void> updatePreferredEndpoint({
    required String deviceId,
    required String clientId,
    required String tlsFingerprint,
    required String endpoint,
  });
  Future<void> updateHostDescriptor({
    required String deviceId,
    required String clientId,
    required String tlsFingerprint,
    required DeviceDescriptor descriptor,
  });
}
