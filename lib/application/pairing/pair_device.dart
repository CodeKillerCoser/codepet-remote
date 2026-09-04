import '../../core/domain/paired_device.dart';
import '../ports/application_log.dart';
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
    this.logger = const NoopApplicationLog(),
  });

  final DeviceRepository repository;
  final DeviceDescriptorProvider descriptorProvider;
  final PairingGateway gateway;
  final ApplicationLog logger;

  @override
  Future<PairedDevice> pair(String rawPayload) async {
    logger.info('QR pairing started');
    try {
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
      logger.info(
        'QR pairing succeeded for device ${registration.device.deviceId}',
      );
      return registration.device;
    } catch (error, stackTrace) {
      logger.warning(
        'QR pairing failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

class PairDiscoveredDeviceUseCase implements DiscoveredDevicePairer {
  const PairDiscoveredDeviceUseCase({
    required this.repository,
    required this.descriptorProvider,
    required this.gateway,
    this.logger = const NoopApplicationLog(),
  });

  final DeviceRepository repository;
  final DeviceDescriptorProvider descriptorProvider;
  final PairingRequestGateway gateway;
  final ApplicationLog logger;

  @override
  Future<PairingRequestExchange> request(PairingCandidate candidate) async {
    logger.info('Discovered pairing started for device ${candidate.deviceId}');
    try {
      final clientId = await repository.loadOrCreateClientId();
      final exchange = await gateway.create(
        candidate: candidate,
        clientId: clientId,
        clientDevice: await descriptorProvider.load(),
      );
      return await _persistAccepted(exchange);
    } catch (error, stackTrace) {
      logger.warning(
        'Discovered pairing request failed for device ${candidate.deviceId}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<PairingRequestExchange> refresh(PairingAttempt attempt) async {
    try {
      final exchange = await gateway.status(
        attempt: attempt,
        clientId: await repository.loadOrCreateClientId(),
      );
      return await _persistAccepted(exchange);
    } catch (error, stackTrace) {
      logger.warning(
        'Pairing status refresh failed for device '
        '${attempt.candidate.deviceId}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<PairingRequestExchange> _persistAccepted(
    PairingRequestExchange exchange,
  ) async {
    final registration = exchange.registration;
    if (registration != null) {
      await repository.register(registration.device, registration.credential);
      logger.info(
        'Discovered pairing succeeded for device ${registration.device.deviceId}',
      );
    }
    return exchange;
  }
}
