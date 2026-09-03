import '../../core/domain/paired_device.dart';
import '../ports/device_identity.dart';
import '../ports/device_repository.dart';
import '../ports/pairing_gateway.dart';

abstract interface class DevicePairer {
  Future<PairedDevice> pair(String rawPayload);
}

class PairDeviceUseCase implements DevicePairer {
  const PairDeviceUseCase({
    required this.repository,
    required this.descriptorProvider,
    required this.gateway,
  });

  final DeviceRepository repository;
  final DeviceDescriptorProvider descriptorProvider;
  final PairingGateway gateway;

  @override
  Future<PairedDevice> pair(String rawPayload) async {
    final clientId = await repository.loadOrCreateClientId();
    final descriptor = await descriptorProvider.load();
    final registration = await gateway.exchange(
      rawPayload: rawPayload,
      clientId: clientId,
      clientDevice: descriptor,
    );
    await repository.register(
      registration.device,
      registration.credential,
    );
    return registration.device;
  }
}
