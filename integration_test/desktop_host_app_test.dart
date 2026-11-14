import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:codepet_connection_engine/codepet_connection_engine.dart' as ce;
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/gateway/connection/engine_gateway_transport.dart';
import 'package:path_provider/path_provider.dart';

import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/ports/pairing_gateway.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/pinned_web_socket_transport.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:codepet_remote/gateway/webrtc/signaling.dart';
import 'package:codepet_remote/gateway/webrtc/webrtc_gateway_transport.dart';
import 'package:codepet_remote/pairing/pairing_service.dart';
import 'package:codepet_remote/security/pinned_tls.dart';

// Run against a real, separately launched desktop App containing only the
// independent Echo fixtures. Defines contain public identity/pin, never a key.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CODEPET_HOST_APP_QA');
  if (enabled) {
    unawaited(
      binding.allTestsPassed.future.then((passed) async {
        final directory = await getApplicationDocumentsDirectory();
        await File('${directory.path}/protocol-qa-result.json').writeAsString(
          jsonEncode({
            'passed': passed,
            'failures': binding.failureMethodsDetails
                .map((failure) => failure.details)
                .toList(),
          }),
        );
      }),
    );
  }

  testWidgets(
    'desktop App and Android App share the generated Gateway contract',
    (tester) async {
      const hostId = String.fromEnvironment('QA_HOST_ID');
      const pin = String.fromEnvironment('QA_HOST_PIN');
      final endpoint = Uri.parse(
        const String.fromEnvironment('QA_GATEWAY_URI'),
      );
      expect(hostId, isNotEmpty);
      expect(pin, matches(RegExp(r'^[0-9a-f]{64}$')));
      final registry = DeviceRegistry(
        metadata: PreferencesMetadataStore(),
        credentials: const SecureCredentialStore(),
      );
      final clientId = await registry.loadOrCreateClientId();
      const descriptor = DeviceDescriptor(
        deviceName: 'Protocol QA Android',
        operatingSystem: 'Android',
        systemVersion: 'API 36 emulator',
      );
      final pairing = LanPairingRequestGateway();
      final candidate = PairingCandidate(
        deviceId: hostId,
        displayName: 'Protocol QA Host',
        host: endpoint.host,
        port: endpoint.port,
        tlsFingerprint: pin,
        hostInitiated: false,
      );
      PairingRegistration? registration;
      for (final device in await registry.load()) {
        if (device.deviceId == hostId) {
          final credential = await registry.readCredential(device);
          if (credential != null) {
            registration = PairingRegistration(
              device: device,
              credential: credential,
            );
          }
        }
      }
      if (registration == null) {
        var exchange = await pairing.create(
          candidate: candidate,
          clientId: clientId,
          clientDevice: descriptor,
        );
        debugPrint('HOST_APP_QA awaiting desktop approval');
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (exchange.registration == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          exchange = await pairing.status(
            attempt: exchange.attempt,
            clientId: clientId,
          );
          expect(exchange.attempt.state, isNot(PairingRequestState.rejected));
          expect(exchange.attempt.state, isNot(PairingRequestState.expired));
        }
        registration = exchange.registration;
        expect(
          registration,
          isNotNull,
          reason: 'Approve Protocol QA Android in the isolated desktop App',
        );
        await registry.register(registration!.device, registration.credential);
      }
      final registered = registration;
      debugPrint('HOST_APP_QA paired credential restored');
      ProtocolGatewayClient clientFor(GatewayTransport transport) =>
          ProtocolGatewayClient(
            transport: transport,
            clientId: clientId,
            clientDevice: descriptor,
            expectedDeviceId: hostId,
            expectedIdentityFingerprint: pin,
          );
      GatewayTransport transportFor(bool rtc) => rtc
          ? WebRtcGatewayTransport(
              signaling: PinnedLanRtcSignaling(
                gatewayUri: endpoint,
                credential: registered.credential,
                certSha256: pin,
              ),
              connectTimeout: const Duration(seconds: 45),
            )
          : PinnedWebSocketGatewayTransport(
              gatewayUri: endpoint,
              credential: registered.credential,
              certSha256: pin,
            );
      ConversationSummary? firstConversation;
      ConversationSummary? otherConversation;
      for (final rtc in [false, true]) {
        final transport = transportFor(rtc), client = clientFor(transport);
        final events = <GatewayEvent>[];
        final subscription = client.events.listen(
          (event) =>
              events.add(event is ObservedGatewayEvent ? event.event : event),
        );
        try {
          final handshake = await client.connect();
          expect(handshake.providers.map((p) => p.id).toSet(), {
            'independent-echo-jsonl',
            'independent-echo-zstd',
            'independent-echo-mux',
          }, reason: 'This probe must never run against personal Providers');
          final heartbeat = client.providerSnapshots.first
              .timeout(const Duration(seconds: 45))
              .then<Object>((value) => value, onError: (Object error) => error);
          var sequence = 0;
          final typed = sdk.ProtocolClient(
            transport,
            requestIdFactory: () => 'qa-${++sequence}',
          );
          for (final profile in ['jsonl', 'zstd', 'mux']) {
            final providerId = 'independent-echo-$profile';
            final provider = await client.describeProvider(providerId);
            final createSelection =
                provider.capabilities.conversationCreate?.selection ??
                provider.capabilities.turnSend;
            final access = createSelection?.accessMode;
            final permission =
                access?.defaultId ??
                access?.availableOptions.first.id ??
                'read-only';
            final conversation = await client.createConversation(
              providerId: providerId,
              title: 'Protocol QA ${rtc ? "RTC" : "LAN"} $profile',
              permissionLevel: permission,
              workspaceRoot: '/tmp/codepet-protocol-qa',
            );
            firstConversation ??= conversation;
            if (rtc && profile == 'jsonl') otherConversation = conversation;
            final interaction = await client.acquireInteraction(conversation);
            final turnCount = !rtc && profile == 'jsonl' ? 22 : 2;
            for (var turnIndex = 0; turnIndex < turnCount; turnIndex++) {
              final text = profile == 'mux' && turnIndex == 1
                  ? 'x${List.filled(4096, "协议联调🙂").join()}'
                  : '协议联调 ${rtc ? "RTC" : "LAN"} $profile $turnIndex 中文🙂';
              final receipt = await client.sendTurn(
                providerId: providerId,
                conversation: conversation,
                clientRequestId: 'qa-${DateTime.now().microsecondsSinceEpoch}',
                capabilityRevision: provider.capabilities.revision,
                text: text,
                selection: interaction.selection,
              );
              final until = DateTime.now().add(const Duration(seconds: 25));
              while (!events.whereType<TurnUpsertedEvent>().any(
                    (e) =>
                        e.turn.id == receipt.turn.id &&
                        e.turn.status.isTerminal,
                  ) &&
                  DateTime.now().isBefore(until)) {
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
              final terminal = events
                  .whereType<TurnUpsertedEvent>()
                  .where(
                    (e) =>
                        e.turn.id == receipt.turn.id &&
                        e.turn.status.isTerminal,
                  )
                  .last;
              expect(terminal.turn.status, TurnStatus.completed);
              expect(
                events
                    .whereType<TurnOutputDeltaEvent>()
                    .where((e) => e.turnId == receipt.turn.id)
                    .map((e) => e.delta)
                    .join(),
                text,
              );
              final snapshot = await client.getConversation(conversation);
              expect(
                snapshot.detail.messages.any((m) => m.content.contains(text)),
                isTrue,
              );
            }
            final route = sdk.RoutedResourceId(
              providerId: providerId,
              nativeResourceId: conversation.resource!.nativeResourceId,
            );
            final recent = await typed.conversationGet(
              sdk.ConversationGetRequest(conversation: route, limit: 1),
            );
            expect(recent.items, isNotEmpty);
            expect(recent.snapshotCursor, isNotEmpty);
            expect(
              recent.pageInfo?.nextCursor,
              isNotNull,
              reason: 'Two completed turns must support an earlier page',
            );
            if (recent.pageInfo?.nextCursor case final String cursor) {
              final older = await typed.conversationGet(
                sdk.ConversationGetRequest(
                  conversation: route,
                  limit: 1,
                  cursor: cursor,
                ),
              );
              expect(older.items, isNotEmpty);
              expect(
                older.items.map((i) => i.toJson()),
                isNot(equals(recent.items.map((i) => i.toJson()))),
              );
            }
            final queue = await client.getInputQueue(conversation);
            expect(queue.conversation.providerId, providerId);
            debugPrint(
              'HOST_APP_QA ${rtc ? "RTC" : "LAN"} $profile messages/history/queue passed',
            );
          }
          expect(await heartbeat, hasLength(3));
          debugPrint(
            'HOST_APP_QA ${rtc ? "RTC" : "LAN"} application heartbeat passed',
          );
        } finally {
          await subscription.cancel();
          await client.close();
        }
      }
      // Exercise the production App composition and its real restore/reconnect path.
      await tester.pumpWidget(CodePetRemoteApp(registry: registry));
      final providerChip = find.byKey(
        const Key('provider-independent-echo-jsonl'),
      );
      for (var i = 0; i < 100 && providerChip.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(providerChip, findsOneWidget);
      await tester.ensureVisible(providerChip);
      await tester.tap(providerChip);
      await tester.pump(const Duration(seconds: 1));
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      final directory = await getApplicationDocumentsDirectory();
      await File('${directory.path}/protocol-qa-home.png')
          .writeAsBytes(await binding.takeScreenshot('protocol-qa-home'));
      await tester.tap(find.byKey(const Key('chat-project-card')));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find
            .textContaining('Protocol QA LAN jsonl')
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.textContaining('Protocol QA LAN jsonl'), findsWidgets);
      final tile = find.byKey(Key('conversation-${firstConversation!.id}'));
      expect(tile, findsWidgets);
      await tester.tap(tile.first);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find
            .byKey(const Key('conversation-composer'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const Key('conversation-composer')), findsOneWidget);
      final earlier = find.byKey(const Key('show-earlier-messages'));
      final historyScrollable = find
          .descendant(
            of: find.byKey(const Key('conversation-detail')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (var page = 0; page < 4; page++) {
        await tester.scrollUntilVisible(
          earlier,
          -700,
          scrollable: historyScrollable,
          maxScrolls: 30,
        );
        await tester.tap(earlier);
        await tester.pump(const Duration(seconds: 1));
        if (find
            .textContaining('LAN jsonl 0 中文', findRichText: true)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      for (var attempt = 0; attempt < 30; attempt++) {
        if (find
            .textContaining('LAN jsonl 0 中文', findRichText: true)
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.drag(
          find.byKey(const Key('conversation-detail')),
          const Offset(0, 450),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      await File('${directory.path}/protocol-qa-history.png')
          .writeAsBytes(await binding.takeScreenshot('protocol-qa-history'));
      if (find
          .textContaining('LAN jsonl 0 中文', findRichText: true)
          .evaluate()
          .isEmpty) {
        final texts = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((w) => w.text.toPlainText())
            .where((s) => s.isNotEmpty)
            .take(30);
        debugPrint(
          'HOST_APP_QA history visible: ${texts.map((s) => s.length > 90 ? s.substring(0, 90) : s).toList()}',
        );
      }
      expect(
        find.textContaining('LAN jsonl 0 中文', findRichText: true),
        findsWidgets,
      );
      debugPrint('HOST_APP_QA production UI manual earlier history passed');

      final input = find.descendant(
        of: find.byKey(const Key('conversation-composer')),
        matching: find.byType(TextField),
      );
      for (var i = 0; i < 100; i++) {
        if (input.evaluate().isNotEmpty &&
            tester.widget<TextField>(input.first).enabled == true) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.widget<TextField>(input.first).enabled, isTrue);
      const uiText = 'UI 联调消息 中文🌟';
      await tester.enterText(input.first, uiText);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('发送').last);
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.textContaining(uiText, findRichText: true).evaluate().length >=
                2 &&
            tester.widget<TextField>(input.first).controller!.text.isEmpty) {
          break;
        }
      }
      expect(find.textContaining(uiText, findRichText: true), findsWidgets);
      expect(tester.widget<TextField>(input.first).controller!.text, isEmpty);

      await File(
        '${directory.path}/protocol-qa-conversation.png',
      ).writeAsBytes(await binding.takeScreenshot('protocol-qa-conversation'));
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 500));
      final otherTile = find.byKey(
        Key('conversation-${otherConversation!.id}'),
      );
      await tester.ensureVisible(otherTile.first);
      await tester.tap(otherTile.first);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byKey(const Key('conversation-composer'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(
        find.textContaining(uiText, findRichText: true),
        findsNothing,
        reason: 'A different conversation must not inherit the previous output or draft',
      );
      await File('${directory.path}/protocol-qa-other-conversation.png')
          .writeAsBytes(
            await binding.takeScreenshot('protocol-qa-other-conversation'),
          );
      debugPrint(
        'HOST_APP_QA production UI conversation state isolation passed',
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'HOST_APP_QA production App restore and conversation UI passed',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      if (const bool.fromEnvironment('QA_HOST_RESTART')) {
        var created = 0;
        final session = DeviceSession(device: registered.device,
          reconnectDelays: const [Duration(milliseconds: 100)],
          clientFactory: () {
            created++;
            return clientFor(EngineGatewayTransport(targetId: hostId,
              kinds: [ce.ChannelKind.lan, ce.ChannelKind.relay],
              openTransport: (kind, _) async => transportFor(kind != ce.ChannelKind.lan)));
          });
        try {
          await session.connect();
          expect(session.connectionState.name, 'online');
          debugPrint('HOST_APP_QA awaiting isolated desktop restart');
          final deadline = DateTime.now().add(const Duration(seconds: 120));
          while ((created < 2 || session.connectionState.name != 'online') && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(created, greaterThanOrEqualTo(2), reason: 'A different Host epoch must create a new business session');
          expect(session.connectionState.name, 'online');
          expect(session.handshake!.providers, hasLength(3));
          debugPrint('HOST_APP_QA managed transport rebuilt snapshot after Host restart');
        } finally {
          session.dispose();
        }
      }
      // Revocation must be observed by both native channel implementations.
      final sockets = [transportFor(false), transportFor(true)];
      final clients = sockets.map(clientFor).toList();
      final disconnected = [Completer<void>(), Completer<void>()];
      final watchers = [
        for (var i = 0; i < clients.length; i++)
          clients[i].events.listen(
            (_) {},
            onError: (Object _) {
              if (!disconnected[i].isCompleted) disconnected[i].complete();
            },
          ),
      ];
      try {
        for (final client in clients) {
          await client.connect();
        }
        if (const bool.fromEnvironment('QA_PROVIDER_LIFECYCLE')) {
          const instance = 'independent-echo-lifecycle';
          Future<GatewayProviderChangedEvent> added(ProtocolGatewayClient client) => client.events
              .where((event) => event is GatewayProviderChangedEvent && event.provider.id == instance && event.provider.isAvailable && event.provider.features.contains('agent'))
              .cast<GatewayProviderChangedEvent>().first.timeout(const Duration(seconds: 120));
          final additions = clients.map(added).toList();
          debugPrint('HOST_APP_QA awaiting isolated Provider import');
          final imported = await Future.wait(additions);
          for (final event in imported) {
            expect(event.provider.pluginId, 'independent.echo.lifecycle');
            expect(event.provider.features, ['agent']);
            expect(event.inventoryRevision, isNotNull);
          }
          final removals = [for (final client in clients) client.events
              .where((event) => event is GatewayProviderRemovedEvent && event.providerId == instance)
              .cast<GatewayProviderRemovedEvent>().first.timeout(const Duration(seconds: 120))];
          final snapshots = [for (final client in clients) client.providerSnapshots
              .firstWhere((providers) => !providers.any((p) => p.id == instance))
              .timeout(const Duration(seconds: 120))];
          debugPrint('HOST_APP_QA awaiting isolated Provider removal');
          final removed = await Future.wait(removals);
          for (var i = 0; i < removed.length; i++) {
            expect(removed[i].inventoryRevision, greaterThan(imported[i].inventoryRevision!));
          }
          for (final snapshot in await Future.wait(snapshots)) {
            expect(snapshot.map((p) => p.id).toSet(), {
              'independent-echo-jsonl', 'independent-echo-zstd', 'independent-echo-mux',
            });
          }
          // Removal snapshots are immediate; the next snapshot on each client is its real heartbeat.
          final heartbeatSnapshots = await Future.wait([
            for (final client in clients) client.providerSnapshots.first.timeout(const Duration(seconds: 45)),
          ]);
          for (final snapshot in heartbeatSnapshots) {
            expect(snapshot.any((provider) => provider.id == instance), isFalse);
            expect(snapshot, hasLength(3));
          }
          debugPrint('HOST_APP_QA LAN and native RTC next heartbeat excludes removed Provider');
          final readditions = clients.map(added).toList();
          debugPrint('HOST_APP_QA awaiting isolated Provider reimport');
          final reimported = await Future.wait(readditions);
          for (var i = 0; i < reimported.length; i++) {
            expect(reimported[i].inventoryRevision!, greaterThan(removed[i].inventoryRevision));
          }
          debugPrint('HOST_APP_QA LAN and native RTC import/removal/reimport passed');
        }
        final result = await PinnedTlsConnection(expectedSha256: pin)
            .jsonRequest(
              method: 'DELETE',
              uri: endpoint.replace(
                scheme: 'https',
                path: '/remote/v1/credentials/current',
              ),
              bearer: registered.credential,
            );
        expect(result['revoked'], isTrue);
        await Future.wait(
          disconnected.map(
            (c) => c.future.timeout(const Duration(seconds: 15)),
          ),
        );
        await registry.forget(registered.device);
        debugPrint(
          'HOST_APP_QA LAN and native RTC credential revocation passed',
        );
      } finally {
        for (final watcher in watchers) {
          await watcher.cancel();
        }
        for (final client in clients) {
          await client.close();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
