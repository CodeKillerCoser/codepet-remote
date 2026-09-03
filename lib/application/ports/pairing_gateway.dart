import '../../core/domain/models.dart';
import '../../core/domain/paired_device.dart';

class PairingRegistration {
  const PairingRegistration({
    required this.device,
    required this.credential,
  });

  final PairedDevice device;
  final String credential;
}

abstract interface class PairingGateway {
  Future<PairingRegistration> exchange({
    required String rawPayload,
    required String clientId,
    required DeviceDescriptor clientDevice,
  });
}
