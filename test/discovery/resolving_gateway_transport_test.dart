import 'package:codepet_remote/discovery/codepet_discovery.dart';
import 'package:codepet_remote/discovery/resolving_gateway_transport.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:io';

void main() {
  const trustedId = 'trusted-device';
  DiscoveredCodePetHost host(Map<String, String> txt) =>
      DiscoveredCodePetHost(instanceName: 'CodePet._codepet._tcp.local.', host: 'host.local.', port: 4321, txt: txt);
  const valid = {'id': trustedId, 'name': 'Host', 'vmin': '1', 'vmax': '1', 'pair': '1'};

  test('accepts only the trusted id and a Gateway v2 compatible range', () {
    expect(isTrustedDiscoveryCandidate(host(valid), trustedId), isTrue);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'id': 'other'}), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'vmin': '2'}), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'vmax': '0'}), trustedId), isFalse);
  });

  test('rejects missing or additional TXT keys', () {
    expect(isTrustedDiscoveryCandidate(host({...valid}..remove('pair')), trustedId), isFalse);
    expect(isTrustedDiscoveryCandidate(host({...valid, 'pin': 'untrusted'}), trustedId), isFalse);
  });

  test('builds the emulator alias from the complete paired endpoint shape', () {
    final preferred = Uri.parse(
      'wss://192.168.0.105:43210/remote/v1/gateway?mode=paired',
    );

    expect(
      debugAndroidEmulatorGatewayCandidate(preferred),
      Uri.parse(
        'wss://10.0.2.2:43210/remote/v1/gateway?mode=paired',
      ),
    );
    expect(
      debugAndroidEmulatorGatewayCandidate(Uri.parse('not-an-endpoint')),
      isNull,
    );
  });

  test('tries the debug emulator alias first and marks it ephemeral', () async {
    final preferred = Uri.parse(
      'wss://192.168.0.105:43210/remote/v1/gateway?mode=paired',
    );
    final alias = debugAndroidEmulatorGatewayCandidate(preferred)!;
    final attempted = <Uri>[];
    final credentials = <String>[];
    final pins = <String>[];
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      debugAndroidEmulatorGatewayUri: alias,
      credential: 'same-opaque-credential',
      certSha256: 'a' * 64,
      discovery: _FakeDiscovery(const []),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        credentials.add(credential);
        pins.add(certSha256);
        return _FakeCandidateTransport(succeeds: uri == alias);
      },
    );

    await resolver.connect();

    expect(attempted, [alias]);
    expect(credentials, ['same-opaque-credential']);
    expect(pins, ['a' * 64]);
    expect(resolver.selectedGatewayUri, alias);
    expect(resolver.shouldPersistSelectedGatewayUri, isFalse);
    await resolver.close();
  });

  test('continues through formal candidates and mDNS after alias failure', () async {
    final preferred = Uri.parse(
      'wss://192.168.0.105:43210/remote/v1/gateway',
    );
    final alias = debugAndroidEmulatorGatewayCandidate(preferred)!;
    final matching = host(valid);
    final attempted = <Uri>[];
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      debugAndroidEmulatorGatewayUri: alias,
      credential: 'opaque',
      certSha256: '0' * 64,
      discovery: _FakeDiscovery([matching]),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        if (uri == alias) {
          return _FakeCandidateTransport(
            succeeds: false,
            error: const HandshakeException('certificate pin mismatch'),
          );
        }
        return _FakeCandidateTransport(succeeds: uri.host == matching.host);
      },
    );

    await resolver.connect();

    expect(attempted, [
      alias,
      preferred,
      preferred.replace(
        port: ResolvingPinnedGatewayTransport.stableGatewayPort,
      ),
      preferred.replace(host: matching.host, port: matching.port),
    ]);
    expect(resolver.selectedGatewayUri?.host, matching.host);
    expect(resolver.shouldPersistSelectedGatewayUri, isTrue);
    await resolver.close();
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

  test('times out and closes a stale preferred endpoint before mDNS', () async {
    final preferred = Uri.parse(
      'wss://192.168.0.105:47622/remote/v1/gateway',
    );
    final matching = DiscoveredCodePetHost(
      instanceName: 'Replacement._codepet._tcp.local.',
      host: '192.168.0.106',
      port: 47622,
      txt: valid,
    );
    final attempted = <Uri>[];
    _FakeCandidateTransport? stale;
    var staleClosedBeforeMdns = false;
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      credential: 'opaque',
      certSha256: '0' * 64,
      connectTimeout: const Duration(milliseconds: 10),
      discovery: _FakeDiscovery([matching]),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        if (uri == preferred) {
          final transport = _FakeCandidateTransport(
            succeeds: false,
            connectFuture: Completer<void>().future,
          );
          stale = transport;
          return transport;
        }
        staleClosedBeforeMdns = stale?.closed ?? false;
        return _FakeCandidateTransport(succeeds: true);
      },
    );

    await resolver.connect().timeout(const Duration(seconds: 1));

    expect(attempted, [
      preferred,
      preferred.replace(host: matching.host, port: matching.port),
    ]);
    expect(stale?.closed, isTrue);
    expect(staleClosedBeforeMdns, isTrue);
    expect(resolver.selectedGatewayUri, attempted.last);
    await resolver.close();
  });

  test('times out the first mDNS candidate before trying the second', () async {
    final preferred = Uri.parse(
      'wss://192.168.0.105:47622/remote/v1/gateway',
    );
    final first = DiscoveredCodePetHost(
      instanceName: 'First._codepet._tcp.local.',
      host: '192.168.0.106',
      port: 47622,
      txt: valid,
    );
    final second = DiscoveredCodePetHost(
      instanceName: 'Second._codepet._tcp.local.',
      host: '192.168.0.107',
      port: 47622,
      txt: valid,
    );
    final attempted = <Uri>[];
    _FakeCandidateTransport? firstMdns;
    var firstClosedBeforeSecond = false;
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      credential: 'opaque',
      certSha256: '0' * 64,
      connectTimeout: const Duration(milliseconds: 10),
      discovery: _FakeDiscovery([first, second]),
      transportFactory: (uri, credential, certSha256) {
        attempted.add(uri);
        if (uri == preferred) {
          return _FakeCandidateTransport(succeeds: false);
        }
        if (uri.host == first.host) {
          final transport = _FakeCandidateTransport(
            succeeds: false,
            connectFuture: Completer<void>().future,
          );
          firstMdns = transport;
          return transport;
        }
        firstClosedBeforeSecond = firstMdns?.closed ?? false;
        return _FakeCandidateTransport(succeeds: true);
      },
    );

    await resolver.connect().timeout(const Duration(seconds: 1));

    expect(attempted.map((uri) => uri.host), [
      preferred.host,
      first.host,
      second.host,
    ]);
    expect(firstMdns?.closed, isTrue);
    expect(firstClosedBeforeSecond, isTrue);
    expect(resolver.selectedGatewayUri?.host, second.host);
    await resolver.close();
  });

  test('all candidate timeouts fail retryably within a finite bound', () async {
    final preferred = Uri.parse(
      'wss://192.168.0.105:1111/remote/v1/gateway',
    );
    final matching = DiscoveredCodePetHost(
      instanceName: 'Replacement._codepet._tcp.local.',
      host: '192.168.0.106',
      port: 47622,
      txt: valid,
    );
    final candidates = <_FakeCandidateTransport>[];
    final resolver = ResolvingPinnedGatewayTransport(
      deviceId: trustedId,
      preferredGatewayUri: preferred,
      credential: 'opaque',
      certSha256: '0' * 64,
      connectTimeout: const Duration(milliseconds: 10),
      discovery: _FakeDiscovery([matching]),
      transportFactory: (uri, credential, certSha256) {
        final candidate = _FakeCandidateTransport(
          succeeds: false,
          connectFuture: Completer<void>().future,
        );
        candidates.add(candidate);
        return candidate;
      },
    );

    await expectLater(
      resolver.connect().timeout(const Duration(seconds: 1)),
      throwsA(
        isA<GatewayConnectionException>()
            .having((error) => error.retryable, 'retryable', isTrue)
            .having((error) => error.message, 'message', contains('timed out')),
      ),
    );

    expect(candidates, hasLength(3));
    expect(candidates.every((candidate) => candidate.closed), isTrue);
    expect(resolver.selectedGatewayUri, isNull);
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
  _FakeCandidateTransport({
    required this.succeeds,
    this.error,
    this.connectFuture,
  });
  final bool succeeds;
  final Object? error;
  final Future<void>? connectFuture;
  final StreamController<JsonMap> controller = StreamController<JsonMap>.broadcast();
  bool closed = false;
  @override Stream<JsonMap> get events => controller.stream;
  @override Future<void> connect() async {
    final pending = connectFuture;
    if (pending != null) {
      await pending;
      return;
    }
    if (!succeeds) throw error ?? StateError('unreachable');
  }
  @override Future<Object?> request(Map<String, Object?> request) => throw UnimplementedError();
  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }
}
