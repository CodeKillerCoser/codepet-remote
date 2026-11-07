import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codepet_remote/gateway/webrtc/cloud_signaling.dart';
import 'package:codepet_remote/gateway/webrtc/ice_configuration_cache.dart';
import 'package:codepet_remote/gateway/webrtc/path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_trickle_test.dart' show FakeHttp, FakeResponse;

final state = <String, dynamic>{
  'serviceUrl': 'https://test.invalid',
  'host': 'host',
  'client': 'client',
  'hostPublicKey': 'key',
  'token': 'secret',
};
Map<String, dynamic> configuration(DateTime now) => {
  'expires': now.millisecondsSinceEpoch ~/ 1000 + 3600,
  'trickleIce': true,
  'iceServers': [
    {
      'urls': ['stun:test.invalid:3478'],
    },
    {
      'urls': ['turn:test.invalid:3478'],
      'username': 'user',
      'credential': 'password',
    },
  ],
};

class TrackedHttp extends FakeHttp {
  TrackedHttp(super.handle);
  bool closed = false;
  @override
  void close({bool force = false}) => closed = true;
}

class DeniedResponse extends FakeResponse {
  DeniedResponse() : super({});
  @override
  int get statusCode => 401;
}

class DeniedRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _Headers();
  @override
  bool followRedirects = false;
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async => DeniedResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  set contentType(ContentType? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DeniedHttp extends TrackedHttp {
  DeniedHttp() : super((_, _, _) async => {});
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      DeniedRequest();
}

void main() {
  test(
    'parallel requests and reconnects share ICE; each caller owns its list',
    () async {
      final cache = IceConfigurationCache();
      final pending = Completer<Map<String, dynamic>>();
      var requests = 0;
      Future<Map<String, dynamic>> fetch() {
        requests++;
        return pending.future;
      }

      final a = cache.load(state, fetch), b = cache.load(state, fetch);
      expect(requests, 1);
      pending.complete(configuration(DateTime.now()));
      final first = await a;
      (first['iceServers'] as List).clear();
      expect((await b)['iceServers'], hasLength(2));
      expect((await cache.load(state, fetch))['iceServers'], hasLength(2));
      expect(requests, 1);
    },
  );

  test('expiry margin and capability refresh bound cache lifetime', () async {
    var now = DateTime.utc(2026, 11, 8);
    final cache = IceConfigurationCache(now: () => now);
    var requests = 0;
    Future<Map<String, dynamic>> fetch() async {
      requests++;
      return {
        ...configuration(now),
        'expires': now.millisecondsSinceEpoch ~/ 1000 + 90,
      };
    }

    await cache.load(state, fetch);
    now = now.add(const Duration(seconds: 29));
    await cache.load(state, fetch);
    expect(requests, 1);
    now = now.add(const Duration(seconds: 1));
    await cache.load(state, fetch);
    expect(requests, 2);
    now = now.add(const Duration(minutes: 1));
    await cache.load(state, () async {
      requests++;
      return configuration(now);
    });
    now = now.add(const Duration(minutes: 1));
    await cache.load(state, fetch);
    expect(requests, 4);
  });

  test(
    'service, host, client, key and token changes cannot reuse credentials',
    () async {
      for (final field in state.keys) {
        final cache = IceConfigurationCache();
        var requests = 0;
        Future<Map<String, dynamic>> fetch() async {
          requests++;
          return configuration(DateTime.now());
        }

        await cache.load(state, fetch);
        final changed = {
          ...state,
          field: field == 'serviceUrl' ? 'https://other.invalid' : 'other',
        };
        await cache.load(changed, fetch);
        expect(requests, 2, reason: field);
      }
    },
  );

  test('failed requests are retryable and invalidated pending results cannot repopulate cache', () async {
    final cache = IceConfigurationCache();
    await expectLater(
      cache.load(state, () => throw const SocketException('offline')),
      throwsA(isA<SocketException>()),
    );
    final pending = Completer<Map<String, dynamic>>();
    final old = cache.load(state, () => pending.future);
    cache.invalidate(state);
    var requests = 0;
    Future<Map<String, dynamic>> fetch() async {
      requests++;
      return configuration(DateTime.now());
    }

    await cache.load(state, fetch);
    pending.complete(configuration(DateTime.now()));
    await old;
    await cache.load(state, fetch);
    expect(requests, 1);
    final expired = {...configuration(DateTime.now()), 'expires': 1};
    cache.invalidate(state);
    await expectLater(cache.load(state, () async => expired), throwsException);
    await cache.load(state, fetch);
    expect(requests, 2);
  });

  test('closing a losing candidate cannot abort shared ICE fetch', () async {
    final response = Completer<Map<String, dynamic>>();
    final clients = <TrackedHttp>[];
    var requests = 0;
    await HttpOverrides.runZoned(
      () async {
        final cache = IceConfigurationCache();
        final ipv4 = CloudRtcSignaling(
          state,
          iceCache: cache,
          pathPolicy: RtcPathPolicy.ipv4Direct,
        );
        final relay = CloudRtcSignaling(
          state,
          iceCache: cache,
          pathPolicy: RtcPathPolicy.relay,
        );
        final a = expectLater(ipv4.configuration(), throwsException);
        final b = relay.configuration();
        await Future<void>.delayed(Duration.zero);
        expect(requests, 1);
        ipv4.close();
        expect(clients[0].closed, true);
        expect(clients[2].closed, false);
        response.complete(configuration(DateTime.now()));
        await a;
        final value = await b;
        expect(value['iceTransportPolicy'], 'relay');
        expect(value['iceServers'], hasLength(1));
        expect(relay.trickleEnabled, true);
        expect(clients[2].closed, true);
        relay.close();
        final next = CloudRtcSignaling(
          state,
          iceCache: cache,
          pathPolicy: RtcPathPolicy.ipv4Direct,
        );
        expect((await next.configuration())['iceServers'], hasLength(1));
        expect(requests, 1);
        next.close();
      },
      createHttpClient: (_) {
        final http = TrackedHttp((_, path, _) async {
          expect(path, '/v1/ice');
          requests++;
          return response.future;
        });
        clients.add(http);
        return http;
      },
    );
  });

  test(
    'IPv6 needs no credentials; rejected authorization invalidates cached ICE',
    () async {
      final cache = IceConfigurationCache();
      var fetches = 0;
      Future<Map<String, dynamic>> fetch() async {
        fetches++;
        return configuration(DateTime.now());
      }

      await cache.load(state, fetch);
      await HttpOverrides.runZoned(() async {
        final ipv6 = CloudRtcSignaling(
          {...state, 'seed': base64Encode(List.filled(32, 1))},
          iceCache: cache,
          pathPolicy: RtcPathPolicy.ipv6Direct,
        );
        expect((await ipv6.configuration())['iceServers'], isEmpty);
        await expectLater(
          ipv6.answer({'sdp': 'test', 'type': 'offer'}),
          throwsException,
        );
        ipv6.close();
        await Future<void>.delayed(Duration.zero);
      }, createHttpClient: (_) => DeniedHttp());
      await cache.load(state, fetch);
      expect(fetches, 2);
    },
  );
}
