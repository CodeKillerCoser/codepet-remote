import 'dart:async';

import 'package:codepet_connection_engine/codepet_connection_engine.dart' as ce;

import '../../application/errors/application_failures.dart';
import '../../discovery/codepet_discovery.dart';
import '../../discovery/resolving_gateway_transport.dart';
import '../webrtc/cloud_signaling.dart';
import '../webrtc/ice_configuration_cache.dart';
import '../webrtc/path_policy.dart';
import '../webrtc/rtc_diagnostics.dart';
import '../webrtc/webrtc_gateway_transport.dart';
import 'engine_gateway_transport.dart';

/// Platform IO composition; the core never reads storage, SDP, VPN or discovery.
EngineGatewayTransport createDeviceConnection({
  required String deviceId,
  required Uri preferredGatewayUri,
  Uri? debugAndroidEmulatorGatewayUri,
  required String credential,
  required String certSha256,
  CodePetHostDirectory? hostDirectory,
  String? signalingService,
  required bool webRtcEnabled,
  required ce.CandidateBudget budget,
}) {
  final pairing = CloudPairing(deviceId, credential, certSha256);
  final iceCache = IceConfigurationCache();
  Future<Map<String, dynamic>?>? loading;
  Future<Map<String, dynamic>?> load() =>
      loading ??= pairing.load().whenComplete(() => loading = null);
  return EngineGatewayTransport(
    targetId: deviceId,
    budget: budget,
    onPreparedEndpoint: pairing.bootstrap,
    kinds: webRtcEnabled ? ce.ChannelKind.values : [ce.ChannelKind.lan],
    openTransport: (kind, cancel) async {
      cancel.check();
      if (kind == ce.ChannelKind.lan) {
        return ResolvingPinnedGatewayTransport(
          deviceId: deviceId,
          preferredGatewayUri: preferredGatewayUri,
          debugAndroidEmulatorGatewayUri: debugAndroidEmulatorGatewayUri,
          credential: credential,
          certSha256: certSha256,
          hostDirectory: hostDirectory,
          enableChannelControl: true,
        );
      }
      final state = await load();
      cancel.check();
      if (state == null || state['token'] == null) {
        throw const GatewayConnectionException('尚无公网通道授权', retryable: true);
      }
      validateSignalingServiceBinding(state, signalingService);
      final policy = switch (kind) {
        ce.ChannelKind.ipv6Direct => RtcPathPolicy.ipv6Direct,
        ce.ChannelKind.ipv4Direct => RtcPathPolicy.ipv4Direct,
        _ => RtcPathPolicy.relay,
      };
      final diagnostics = RtcDiagnostics(
        targetId: rtcOfferId(deviceId),
        pathPolicy: policy.wireName,
      );
      return WebRtcGatewayTransport(
        signaling: CloudRtcSignaling(
          state,
          pathPolicy: policy,
          diagnostics: diagnostics,
          iceCache: iceCache,
        ),
        pathPolicy: policy,
        diagnostics: diagnostics,
        enableChannelControl: true,
        connectTimeout: const Duration(seconds: 55),
      );
    },
  );
}
