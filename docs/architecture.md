# CodePet Remote architecture

The Remote client is split by dependency direction:

1. `lib/core/domain` contains protocol-neutral models and state transitions.
2. `lib/core/ports` contains application-facing contracts such as
   `GatewayClient`; it does not import discovery, WebSocket, or generated SDK
   packages.
3. `lib/application` coordinates device sessions, snapshots, event cursor
   fences, pagination, and reconnect policy through Core ports.
4. `lib/gateway`, `lib/discovery`, and `lib/pairing` are infrastructure
   adapters. UI features depend on Application/Core rather than transport
   implementations.
5. `lib/features` owns presentation state and widgets only.

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
