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
  binding, interaction acquisition and retry, sending, and terminal reconciliation.
- `PairDeviceUseCase` owns pairing orchestration and persistence; the LAN
  adapter owns QR/generated DTO validation and pinned HTTPS exchange.

## Conversation entry

Remote enters a writable conversation through Gateway `conversation.resume(limit=20)`.
Host acquires interaction first, then reuses `conversation.get` for the first page.
The response keeps interaction and history outcomes separate, so a history failure
cannot erase acquired interaction. Codex uses `thread/resume(excludeTurns=true)`;
its raw full-history response does not pass through get's pagination protection.

The controller opens its event window before resume, uses the returned interaction
to enable the composer, and passes the returned history into the existing get
assembler. A present empty page is loaded history, not a reason to fetch again.
When interaction is denied and history is absent, get loads read-only history.
Remaining pages are still fetched automatically, initially 20 turns per request;
`provider_response_too_large` retries the same cursor at 10, 5, then 1. A first-page
error returned by resume uses this same retry path without repeating acquisition.
Successful acquisition has no renewal timer. Only failed acquisition is retried. Generation checks reject a resumed result
after navigation or reconnection; capability binding includes capabilitiesLoaded
so a complete description with the same revision can restart a pending load.

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
release it. The final client disconnect, or a heartbeat timeout, stops Harness
including active turns; the Provider plugin remains running. Multiple phones
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
