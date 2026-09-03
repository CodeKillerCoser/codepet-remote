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
  binding, interaction lease renewal, sending, and terminal reconciliation.
- `PairDeviceUseCase` owns pairing orchestration and persistence; the LAN
  adapter owns QR/generated DTO validation and pinned HTTPS exchange.

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
