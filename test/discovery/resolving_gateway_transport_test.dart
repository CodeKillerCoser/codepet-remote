import 'package:codepet_remote/discovery/codepet_discovery.dart';
import 'package:codepet_remote/discovery/resolving_gateway_transport.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

void main() {
  const trustedId = 'trusted-device';
  DiscoveredCodePetHost host(Map<String, String> txt) =>
      DiscoveredCodePetHost(instanceName: 'CodePet._codepet._tcp.local.', host: 'host.local.', port: 4321, txt: txt);
  const valid = {'id': trustedId, 'name': 'Host', 'vmin': '1', 'vmax': '1', 'pair': '1'};

  test('accepts only the trusted id and a Gateway v1 compatible range', () {
    expect(isTrustedDiscoveryCandidate(host(valid), trustedId), isTrue);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'id': 'other'}), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'vmin': '2'}), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'vmax': '0'}), trustedId), isFalse);
  });

  test('rejects missing or additional TXT keys', () {
    expect(isTrustedDiscoveryCandidate(host({...valid}..remove('pair')), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'pin': 'untrusted'}), trustedId), isFalse);
  });

  test('falls back from the preferred endpoint to only a trusted discovery candidate', () async {
    final attempted = <Uri>[];
    final matching = host(valid);
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: Uri.parse('wss://old.local:1111/remote/v1/gateway'),
      credential: 'opaque',
      certSha256: '0' * 64,
      discovery: _FakeDiscovery([
        host({...valid, 'id': 'other'}),
        matching,
      ]),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        return _FakeCandidateTransport(succeeds: uri.host == matching.host);
      },
    );

    await resolver.connect();
    expect(
      attempted.map((uri) => '${uri.host}:${uri.port}'),
      ['old.local:1111', 'old.local:47622', '${matching.host}:4321'],
    );
    expect(resolver.selectedGatewayUri?.host, matching.host);
    expect(resolver.selectedGatewayUri?.port, matching.port);
    await resolver.close();
  });

  test('tries the stable port with the original URI before discovery', () async {
    final discovery = _FakeDiscovery([host(valid)]);
    final attempted = <Uri>[];
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: Uri.parse(
        'wss://old.local:1111/remote/v1/gateway?mode=paired',
      ),
      credential: 'opaque',
      certSha256: '0' * 64,
      discovery: discovery,
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        return _FakeCandidateTransport(
          succeeds: uri.port == ResolvingPinnedGatewayTransport.stableGatewayPort,
        );
      },
    );

    await resolver.connect();

    expect(attempted, [
      Uri.parse('wss://old.local:1111/remote/v1/gateway?mode=paired'),
      Uri.parse('wss://old.local:47622/remote/v1/gateway?mode=paired'),
    ]);
    expect(discovery.discoverCalls, 0);
    expect(resolver.selectedGatewayUri, attempted.last);
    await resolver.close();
  });

  test('does not retry the preferred endpoint when it is already stable', () async {
    final attempted = <Uri>[];
    final matching = DiscoveredCodePetHost(
      instanceName: 'CodePet._codepet._tcp.local.',
      host: 'host.local.',
      port: ResolvingPinnedGatewayTransport.stableGatewayPort,
      txt: valid,
    );
    final preferred = Uri.parse(
      'wss://${matching.host}:47622/remote/v1/gateway',
    );
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      credential: 'opaque',
      certSha256: '0' * 64,
      discovery: _FakeDiscovery([matching]),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        return _FakeCandidateTransport(succeeds: false);
      },
    );

    await expectLater(resolver.connect(), throwsA(isA<GatewayConnectionException>()));

    expect(attempted, [preferred]);
    await resolver.close();
  });

  test('stable fallback preserves a non-retryable authentication failure', () async {
    final attempted = <Uri>[];
    final credentials = <String>[];
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: Uri.parse(
        'wss://old.local:1111/remote/v1/gateway',
      ),
      credential: 'same-opaque-credential',
      certSha256: '0' * 64,
      discovery: _FakeDiscovery(const []),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        credentials.add(credential);
        return _FakeCandidateTransport(
          succeeds: false,
          error: const GatewayConnectionException('authentication rejected'),
        );
      },
    );

    await expectLater(
      resolver.connect(),
      throwsA(
        isA<GatewayConnectionException>().having(
          (error) => error.retryable,
          'retryable',
          isFalse,
        ),
      ),
    );

    expect(attempted.map((uri) => uri.port), [1111, 47622]);
    expect(credentials, ['same-opaque-credential', 'same-opaque-credential']);
    await resolver.close();
  });
}

class _FakeDiscovery extends CodePetDiscovery {
  _FakeDiscovery(this.hosts);
  final List<DiscoveredCodePetHost> hosts;
  int discoverCalls = 0;
  @override
  Stream<DiscoveredCodePetHost> discover({Duration timeout = const Duration(seconds: 4)}) {
    discoverCalls++;
    return Stream.fromIterable(hosts);
  }
}

class _FakeCandidateTransport implements GatewayTransport {
  _FakeCandidateTransport({required this.succeeds, this.error});
  final bool succeeds;
  final Object? error;
  final StreamController<JsonMap> controller = StreamController<JsonMap>.broadcast();
  @override Stream<JsonMap> get events => controller.stream;
  @override Future<void> connect() async {
    if (!succeeds) throw error ?? StateError('unreachable');
  }
  @override Future<JsonMap> request(String method, JsonMap params) => throw UnimplementedError();
  @override Future<void> close() => controller.close();
}
