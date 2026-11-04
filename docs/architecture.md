# CodePet Remote architecture

The codebase follows an inward dependency rule:

```text
features (Flutter UI) ──> application ──> core/domain
                              ^
                              │ implements application ports
gateway / pairing / devices / discovery / security
```

1. `lib/core/domain` owns stable identities, entities, value objects, and state
   transitions. It cannot import Flutter, I/O, generated SDKs, application code,
   or infrastructure.
2. `lib/application/ports` defines the contracts implemented by infrastructure:
   `GatewayClient`, `DeviceRepository`, device identity, and pairing exchange.
3. `lib/application` owns use-case orchestration. `DeviceSession`, conversation
   detail/search controllers, cursor fences, reconnect policy, and pairing
   coordination are pure Dart and depend only on Core and application ports.
4. `lib/gateway`, `lib/pairing`, `lib/devices`, `lib/discovery`, and
   `lib/security` are outer adapters. They may depend inward and on Flutter,
   platform APIs, generated SDKs, TLS, and storage.
5. `lib/features` owns widgets and ephemeral presentation state. It calls
   application controllers/use cases and never reaches a Gateway client,
   transport, generated DTO, credential store, or TLS implementation directly.
6. `lib/app` is the composition root. It chooses concrete adapters and wires
   them to application ports.

These rules are executable in `test/architecture/layering_test.dart`; a new
forbidden import fails CI.

## Application ownership

- `DeviceSession` owns one Host runtime, reconnection, list projection, and a
  generation-fenced runtime lease. The lease exposes use-case operations, not
  the underlying Gateway client.
- `ConversationSearchController` owns query generation, pagination, stale
  response rejection, and view state.
- `ConversationDetailController` owns snapshot/event fencing, capability
  binding, interaction acquisition and retry, sending, and manual history pagination.
- `ConversationMessageCache`, owned by `DeviceSession`, retains message sources and
  their live event windows across screen navigation.
- `PairDeviceUseCase` owns pairing orchestration and persistence; the LAN
  adapter owns QR/generated DTO validation and pinned HTTPS exchange.

## Conversation entry

Remote enters a writable conversation through Gateway `conversation.resume(limit=20)`.
When interaction acquisition reports a write conflict (or a previous force takeover
failed) for an idle conversation with no active turn,
Remote offers an explicit force takeover action and explains that it ends Codex
processes and tasks outside Codepet management, including independent CLI sessions. Only this action sends `conversation.resume(force=true)`;
normal entry omits force and automatic retries never force. The Host rechecks
activity and preserves Codex processes carrying the harness environment marker
`CODEPET_CODEX_HARNESS`, as well as Codepet itself, before terminating unmanaged
Codex processes.
The action is hidden while acquisition is in flight and runtime fences reject stale results.

Host acquires interaction first, then reuses `conversation.get` for the first page.
The response keeps interaction and history outcomes separate, so a history failure
cannot erase acquired interaction. Codex uses `thread/resume(excludeTurns=true)`;
its raw full-history response does not pass through get's pagination protection.

The controller opens its event window before resume, uses the returned interaction
to enable the composer, and installs only the returned history page. A present empty page is loaded history, not a reason to fetch again.
When interaction is denied and history is absent, get loads read-only history.
Older pages are fetched only when the user asks to see earlier messages,
initially 20 turns per request;
`provider_response_too_large` retries the same cursor at 10, 5, then 1. A first-page
error returned by resume uses this same retry path without repeating acquisition.
Successful acquisition has no renewal timer. Only failed acquisition is retried. Generation checks reject a resumed result
after navigation or reconnection; capability binding includes capabilitiesLoaded
so a complete description with the same revision can restart a pending load.

## Immediate interaction release

Providers advertising `conversation.releaseInteraction` expose an immediate release
in the conversation actions menu. This stops that Provider instance's shared harness
server, including active tasks in its other conversations; it is not a single-turn
interrupt. The response acknowledges `released: true` with `scope: providerInstance`.

Before sending the request, the device session pauses automatic interaction acquisition
for the entire Provider, revokes cached interaction flags, and fences late acquisition
responses. The pause survives navigation, history refresh, and reconnection. It also
survives release errors/timeouts, since the server may already have stopped. The user
can retry release or explicitly select “重新接管” to resume. The Provider must keep
heartbeat and background reads from silently starting a released harness.

## Incremental message sources and eviction

Initial load installs one page with its event-window fence. Older-page requests
prepend unseen `(turnId, itemId)` identities, preserve observed messages and turn
state, and never replace the live event fence. One older-page request runs per
source; failures retain the cursor for retry. Repeated cursors fail visibly.
Deltas append or update the same item; canonical item events replace it in place.
Message order preserves first observation, including output retained across turns.
Terminal turn events stop streaming and update status without fetching history.

The session cache keys sources by routed conversation identity and validates the
runtime/capability binding. Visits and leaving the page update LRU access order;
background events do not. The default capacity is 8 sources, with visible sources
pinned. Idle sources expire after 15 minutes, checked each minute and on access.
Eviction closes the event window and drops the source. A cached source continues
receiving events off screen; returning reuses it while reacquiring interaction.
Opening an evicted source loads a fresh first page. Runtime disconnect/reconnect
clears all sources; Provider generation, revision or availability changes invalidate
that Provider's sources. This avoids treating missed events as a valid cache.

The count and idle timeout limit retained conversations, not the bytes of a single
large, actively viewed conversation. Paging never walks all cursors automatically.
Explicit refresh and recovery after an unknown send outcome fetch the latest page;
normal terminal events do not. Native Codex history projection failures remain an
upstream issue and can still affect a fresh load after cache eviction.

## Connection heartbeat and Provider presence

The Gateway SDK owns a single-in-flight application heartbeat (20 second interval,
10 second request timeout, 60 seconds without a valid pong before failure). It
uses protocol.ping and passes compact Provider summaries through a separate
ProviderSnapshotGatewayClient stream. These snapshots never advance an event
cursor. Socket closure or generation replacement cancels the heartbeat and late
responses are ignored. Provider events received during a ping take precedence
over its later snapshot.

DeviceSession merges status by provider ID and runtime generation, keeps complete
capabilities when the revision is unchanged, and lazily describes new revisions.
Provider health (connecting/online/offline) is distinct from Harness status.
Capabilities arriving after the initial list, or a Provider becoming available,
trigger project loading; summaries with empty methods are not capability denial.
Detail bindings include capability-loaded state, Provider generation and availability.

Host keeps each authenticated connection independently. Host→Provider SDK pings
carry that connection set; a Server-mode Provider instance shares one Harness
Server across every resumed conversation. Leaving detail does not unsubscribe or
release it. In the current Provider SDK, the final client disconnect retains
in-flight requests, active turns and pending approvals; the Harness is stopped
once idle. Host-to-Provider heartbeat loss still forces cleanup, as does explicit
interaction release. The Provider plugin remains running. Multiple phones
connecting to the same Host therefore share the same Server. New Remote, Host,
and SDK versions must be deployed together; old clients lack application pings.

## Generated Gateway boundary

CodePet's JSON Schema and manifest are the single source of truth for Gateway
JSON-RPC. Every request, response, envelope, and event payload crossing the
Gateway boundary must use classes from `codepet_gateway_sdk`. Remote may add a
mapper from generated values to Core domain models, but must not add handwritten
wire DTOs or reconstruct a generated payload as a second protocol model.

Transport implementations only move generated JSON-RPC envelopes. Adding a
Gateway method or field therefore starts in CodePet's protocol source, runs the
CodePet generator, updates the vendored SDK package, and finally updates the
generated-to-domain mapper and feature code.

Provider plugins advertise stable identity metadata through the handshake. The
UI consumes `displayName` and optional `icon`, with a generic local fallback for
older Hosts.

## Persistence and failure boundaries

Device metadata mutations are serialized. Credential replacement rolls back if
metadata commit fails, and forgetting removes local metadata/credentials before
best-effort remote revocation. `dart:io` failures are normalized by adapters to
application failures at the boundary.

## Item metadata and tool text truncation

All Agent item variants accept optional open `_meta` (SDK field `meta`). The mapper preserves it on `GatewayMessage` and through `copyWith`. Provider mappers currently detect oversized text only inside `kind: tool`, retain UTF-8-safe head/tail within 256 KiB per field, and write `_meta.truncations` records with JSON Pointer paths, original/retained byte counts and strategy. The UI derives existing input/output truncation indicators from those records; old per-input/block `truncation` remains a decoding fallback. Unknown metadata stays intact. This policy has no turn/item-count or cumulative page text budget. Remote still fetches all history with an initial 20-turn page, reducing its own request limit only after a final Provider wire overflow. Deploy the regenerated SDK with the Provider because older strict decoders reject the new optional field.

## Android system notifications

`NotificationCoordinator` consumes fenced device-wide events, independently of
conversation screens and the bounded message cache. `TaskOutcome` is a terminal
fact; `InterventionRequest` is a pending/resolved/cancelled/expired request with
an approval/input/decision kind. Current Gateway approvals have structured IDs;
waiting-user-input summaries produce a generic reminder, not an invented question
or a new input submission API. Structured input/decision support still needs a
Host/SDK contract.

The application wires `DeviceSession.onLiveEvent` and the initial conversation
snapshot into the coordinator. It never forwards output deltas to notification
storage. Initial snapshots reconcile waiting states but do not announce old
completions. Terminal events older than ten minutes and interrupted turns do not
alert. A seven-day, 512-entry ledger persists scoped identities, notification IDs,
versions and delivery/resolution state, not message bodies or credentials.
Deduplication is bounded by that retention; it is not an exactly-once guarantee.

Settings are opt-in: task outcomes, intervention requests, content previews and
background connection. Viewing a conversation suppresses its new system alerts;
viewing/dismissing a notification never resolves an approval. Pending changes
update one notification, structured approvals replace generic summaries silently,
and resolution cancels the notification. Preview is off by default; enabling it
still marks the notification private on the lock screen. Android channels allow
independent sound/importance controls. Permission denial leaves the toggle off.

`LocalNotificationAdapter` implements the application port with
`flutter_local_notifications`. Launch payloads contain only scoped routing IDs.
The app validates the paired device and Provider, reconnects if needed, fetches the
current conversation and navigates without submitting an approval. The detail
screen refreshes history before locating a notification target; if an older
result is outside the loaded history page it offers the existing history path.

`CodePetApplication` owns one Flutter engine, including the mDNS bridge, across
Activity recreation. A user-enabled `connectedDevice` foreground service keeps
the process eligible to receive direct-device events while the UI is backgrounded.
It has a low-importance persistent notification and is not sticky: OS/user
termination does not silently restart sessions. It is started only while the
Activity is resumed, or while that service already exists. This does not bypass
Doze, network loss, force-stop or vendor battery restrictions and is not remote
push. The service is stopped when the setting is disabled or all devices are
forgotten.

### Remaining Host/push work

The current Host repository (`CodeKillerCoser/codepet`, inspected at `b84689f`)
already retains active execution and pending approvals after the last Remote
connection disappears. `sdk/rust/codepet-provider-sdk/src/runtime/activity.rs`
tracks these independently of connection presence; `runtime/heartbeat.rs` stops
only when idle while the Host still owns the instance. Host heartbeat loss,
instance removal and explicit release retain forced cleanup semantics. The
Codex vertical tests include offline execution and offline approval retention.
The companion Host SDK implementation
replaces heartbeat lifecycle control with a single activity-based idle scheduler.
Heartbeat handlers never call instance start/stop. Unfinished turns, approvals,
waiting input, admitted requests and uncertain send outcomes prevent automatic
release. Once business activity ends, a separate idle window (default five
minutes) allows release whether the phone is online or offline. Host startup and
history reads can start a fresh Server; startup does not resume all old
conversations. Explicit release and true process/IPC shutdown retain their
existing semantics. The companion Host/Provider changes must be built and
installed; updating this Android App alone does not deploy them.
The SDK runtime test selection was run during the notification change: 21 passed, 2 ignored.
The Codex binary vertical tests were inspected but not rerun. Older Host
installations may still stop tasks on final disconnect and should be
upgraded. No fake client or heartbeat is introduced by this Remote change.

This is process-lifetime retention, not durable task recovery across Host/Provider
restart. This App change does not add a push backend or a durable Host outbox.
A subsequent push adapter needs authenticated per-installation subscriptions,
revocation on unpair, token rotation, a durable Host outbox with retry/expiry,
minimal or encrypted notification payloads, and the same scoped event/request
identities for deduplicating direct and push delivery. The existing cloud RTC
signaling service is not a notification push provider. Authoritative pending
request enumeration/reconciliation is also needed to recover interventions in
unloaded conversations after an offline interval; the current app can reconcile
only received events and loaded conversation snapshots.

### Validation

Pure Dart tests exercise replay/restart deduplication, cross-device identities,
permission denial, delivery failure, stale pending events, resolution, and privacy.
Widget tests cover settings and stale approval navigation. The Android integration
test verifies real channels, notification posting/cancellation and foreground
service start/stop. Run `python3 tool/run_notification_probe.py --device emulator-5580` on an isolated
emulator (`--adb /path/to/adb` if needed). The driver allows the permission prompt,
taps the intervention notice, backgrounds the app with Activity destruction
enabled, and taps the subsequent outcome notification. It restores the emulator
setting afterward.
This verifies Activity recreation with the retained engine. It does not simulate
process-death cold launch, Doze survival, or delivery from an offline Host.
