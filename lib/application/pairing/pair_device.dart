import '../../core/domain/paired_device.dart';
import '../ports/device_identity.dart';
import '../ports/device_repository.dart';
import '../ports/pairing_gateway.dart';

abstract interface class DevicePairer {
  Future<PairedDevice> pair(String rawPayload);
}

abstract interface class DiscoveredDevicePairer {
  Future<PairingRequestExchange> request(PairingCandidate candidate);
  Future<PairingRequestExchange> refresh(PairingAttempt attempt);
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

class PairDiscoveredDeviceUseCase implements DiscoveredDevicePairer {
  const PairDiscoveredDeviceUseCase({
    required this.repository,
    required this.descriptorProvider,
    required this.gateway,
  });

  final DeviceRepository repository;
  final DeviceDescriptorProvider descriptorProvider;
  final PairingRequestGateway gateway;

  @override
  Future<PairingRequestExchange> request(PairingCandidate candidate) async {
    final clientId = await repository.loadOrCreateClientId();
    final exchange = await gateway.create(
      candidate: candidate,
      clientId: clientId,
      clientDevice: await descriptorProvider.load(),
    );
    return _persistAccepted(exchange);
  }

  @override
  Future<PairingRequestExchange> refresh(PairingAttempt attempt) async {
    final exchange = await gateway.status(
      attempt: attempt,
      clientId: await repository.loadOrCreateClientId(),
    );
    return _persistAccepted(exchange);
  }

  Future<PairingRequestExchange> _persistAccepted(
    PairingRequestExchange exchange,
  ) async {
    final registration = exchange.registration;
    if (registration != null) {
      await repository.register(registration.device, registration.credential);
    }
    return exchange;
  }
}
