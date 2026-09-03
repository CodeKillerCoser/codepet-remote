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

class PairingCandidate {
  const PairingCandidate({
    required this.deviceId,
    required this.displayName,
    required this.host,
    required this.port,
    required this.tlsFingerprint,
    required this.hostInitiated,
  });

  final String deviceId;
  final String displayName;
  final String host;
  final int port;
  final String tlsFingerprint;
  final bool hostInitiated;
}

enum PairingRequestState { pending, accepted, rejected, expired }

class PairingAttempt {
  const PairingAttempt({
    required this.candidate,
    required this.requestId,
    required this.clientNonce,
    required this.state,
    required this.expiresAt,
    required this.localPollDeadline,
    required this.confirmationCode,
  });

  final PairingCandidate candidate;
  final String requestId;
  final String clientNonce;
  final PairingRequestState state;
  final DateTime expiresAt;
  final DateTime localPollDeadline;
  final String confirmationCode;

  PairingAttempt copyWith({PairingRequestState? state}) => PairingAttempt(
        candidate: candidate,
        requestId: requestId,
        clientNonce: clientNonce,
        state: state ?? this.state,
        expiresAt: expiresAt,
        localPollDeadline: localPollDeadline,
        confirmationCode: confirmationCode,
      );
}

class PairingRequestExchange {
  const PairingRequestExchange({required this.attempt, this.registration});

  final PairingAttempt attempt;
  final PairingRegistration? registration;
}

abstract interface class PairingRequestGateway {
  Future<PairingRequestExchange> create({
    required PairingCandidate candidate,
    required String clientId,
    required DeviceDescriptor clientDevice,
  });

  Future<PairingRequestExchange> status({
    required PairingAttempt attempt,
    required String clientId,
  });
}
