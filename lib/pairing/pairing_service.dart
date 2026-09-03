import 'dart:math';

import '../core/domain/paired_device.dart';
import '../application/ports/pairing_gateway.dart';
import '../core/domain/models.dart';
import '../security/pinned_tls.dart';
import 'pairing_confirmation.dart';
import 'pairing_models.dart';
import 'package:codepet_lan_channel_sdk/codepet_lan_channel_sdk.dart' as sdk;

const _pairingRequestLocalWait = Duration(minutes: 2, seconds: 5);

abstract interface class PairingExchangeClient {
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap? body,
    String method = 'POST',
  });
}

class PinnedPairingExchangeClient implements PairingExchangeClient {
  const PinnedPairingExchangeClient();

  @override
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap? body,
    String method = 'POST',
  }) =>
      PinnedTlsConnection(expectedSha256: expectedFingerprint).jsonRequest(
        method: method,
        uri: uri,
        body: body,
      );
}

class LanPairingGateway implements PairingGateway {
  const LanPairingGateway({
    this.exchangeClient = const PinnedPairingExchangeClient(),
  });

  final PairingExchangeClient exchangeClient;

  @override
  Future<PairingRegistration> exchange({
    required String rawPayload,
    required String clientId,
    required DeviceDescriptor clientDevice,
  }) async {
    final qr = PairingQrPayload.parse(rawPayload);
    final json = await exchangeClient.exchange(
      expectedFingerprint: qr.certSha256,
      uri: qr.exchangeUrl,
      body: sdk.PairingExchangeRequest.fromJson({
        'pairingSecret': qr.pairingSecret,
        'clientId': clientId,
        'device': clientDevice.toJson(),
      }).toJson(),
    );
    final response = PairingExchangeResponse.fromJson(json);
    if (response.device.deviceId != qr.hostDeviceId ||
        !constantTimeEquals(
          response.device.identityFingerprint,
          qr.certSha256,
        ) ||
        !_isGatewayLocator(response.gatewayUrl)) {
      throw const FormatException('Pairing identity or endpoint mismatch');
    }
    final credentialKey =
        'gateway-v1-credential:${qr.hostDeviceId}:$clientId';
    final device = PairedDevice(
      deviceId: qr.hostDeviceId,
      displayName: response.device.descriptor.deviceName,
      descriptor: response.device.descriptor,
      tlsFingerprint: qr.certSha256,
      endpointHints: [qr.httpsBaseUrl.toString()],
      credentialKeyRef: credentialKey,
      clientId: clientId,
      preferredEndpoint: response.gatewayUrl.toString(),
      autoConnect: true,
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    return PairingRegistration(
      device: device,
      credential: response.credential,
    );
  }
}

class LanPairingRequestGateway implements PairingRequestGateway {
  const LanPairingRequestGateway({
    this.exchangeClient = const PinnedPairingExchangeClient(),
  });

  final PairingExchangeClient exchangeClient;

  @override
  Future<PairingRequestExchange> create({
    required PairingCandidate candidate,
    required String clientId,
    required DeviceDescriptor clientDevice,
  }) async {
    final clientNonce = _secureNonce();
    final endpoint = Uri(
      scheme: 'https',
      host: candidate.host,
      port: candidate.port,
      path: '/remote/v1/pairing-requests',
    );
    final json = await exchangeClient.exchange(
      expectedFingerprint: candidate.tlsFingerprint,
      uri: endpoint,
      body: sdk.PairingRequestCreateRequest(
        hostDeviceId: candidate.deviceId,
        clientId: clientId,
        device: sdk.DeviceDescriptor.fromJson(clientDevice.toJson()),
        clientNonce: clientNonce,
      ).toJson(),
    );
    return _decode(
      candidate,
      clientId,
      json,
      clientNonce: clientNonce,
    );
  }

  @override
  Future<PairingRequestExchange> status({
    required PairingAttempt attempt,
    required String clientId,
  }) async {
    final candidate = attempt.candidate;
    final endpoint = Uri(
      scheme: 'https',
      host: candidate.host,
      port: candidate.port,
      path:
          '/remote/v1/pairing-requests/${Uri.encodeComponent(attempt.requestId)}',
    );
    final json = await exchangeClient.exchange(
      expectedFingerprint: candidate.tlsFingerprint,
      uri: endpoint,
      body: null,
      method: 'GET',
    );
    return _decode(
      candidate,
      clientId,
      json,
      clientNonce: attempt.clientNonce,
      previous: attempt,
    );
  }

  PairingRequestExchange _decode(
    PairingCandidate candidate,
    String clientId,
    JsonMap json, {
    required String clientNonce,
    PairingAttempt? previous,
  }) {
    final response = sdk.PairingRequestStatusResponse.fromJson(json);
    final expectedConfirmationCode = derivePairingConfirmationCode(
      requestId: response.requestId,
      clientNonce: clientNonce,
      certificateFingerprint: candidate.tlsFingerprint,
    );
    if (response.device.deviceId != candidate.deviceId ||
        !constantTimeEquals(
          response.device.identityFingerprint,
          candidate.tlsFingerprint,
        ) ||
        !constantTimeEquals(
          response.confirmationCode,
          expectedConfirmationCode,
        ) ||
        previous != null &&
            (response.requestId != previous.requestId ||
                response.confirmationCode != previous.confirmationCode)) {
      throw const FormatException('Pairing request identity mismatch');
    }
    final state = switch (response.state) {
      sdk.PairingRequestState.pending => PairingRequestState.pending,
      sdk.PairingRequestState.accepted => PairingRequestState.accepted,
      sdk.PairingRequestState.rejected => PairingRequestState.rejected,
      sdk.PairingRequestState.expired => PairingRequestState.expired,
    };
    final attempt = PairingAttempt(
      candidate: candidate,
      requestId: response.requestId,
      clientNonce: clientNonce,
      state: state,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        response.expiresAt,
        isUtc: true,
      ),
      localPollDeadline: previous?.localPollDeadline ??
          DateTime.now().toUtc().add(_pairingRequestLocalWait),
      confirmationCode: response.confirmationCode,
    );
    if (state != PairingRequestState.accepted) {
      if (response.gatewayUrl != null || response.credential != null) {
        throw const FormatException(
          'Pending pairing response exposed accepted credentials',
        );
      }
      return PairingRequestExchange(attempt: attempt);
    }
    final gatewayUrl = Uri.tryParse(response.gatewayUrl ?? '');
    final credential = response.credential;
    if (!_isGatewayLocator(gatewayUrl) ||
        credential == null ||
        credential.isEmpty) {
      throw const FormatException('Accepted pairing response is incomplete');
    }
    final descriptor = DeviceDescriptor.fromJson(
      Map<String, dynamic>.from(response.device.descriptor.toJson()),
    );
    return PairingRequestExchange(
      attempt: attempt,
      registration: PairingRegistration(
        device: PairedDevice(
          deviceId: candidate.deviceId,
          displayName: descriptor.deviceName,
          descriptor: descriptor,
          tlsFingerprint: candidate.tlsFingerprint,
          endpointHints: [
            Uri(
              scheme: 'https',
              host: candidate.host,
              port: candidate.port,
            ).toString(),
          ],
          credentialKeyRef:
              'gateway-v1-credential:${candidate.deviceId}:$clientId',
          clientId: clientId,
          preferredEndpoint: gatewayUrl.toString(),
          autoConnect: true,
          connectionKind: DeviceConnectionKind.pairedGateway,
        ),
        credential: credential,
      ),
    );
  }
}

bool _isGatewayLocator(Uri? gatewayUrl) =>
    gatewayUrl != null &&
    gatewayUrl.scheme == 'wss' &&
    gatewayUrl.host.isNotEmpty &&
    gatewayUrl.path == '/remote/v2/gateway' &&
    gatewayUrl.userInfo.isEmpty &&
    gatewayUrl.query.isEmpty &&
    gatewayUrl.fragment.isEmpty;

String _secureNonce() {
  final random = Random.secure();
  const hex = '0123456789abcdef';
  return List<String>.generate(64, (_) => hex[random.nextInt(16)]).join();
}
