---
sidebar_position: 5
---

# Hints

Hints describe disposable, non-authoritative presentation messages. Supply definitions through the `hints` catalog in [server startup](../initializing-krf), then inspect the immutable catalog through [HintRegistry](/api/Networking/hint-registry).

ClientToServer hints support local sending and explicitly authorized server callbacks. ServerToClient hints use explicit recipient sends and a client receipt event. Registering a definition alone sends no Hint traffic.

## Definition fields

| Field | Contract |
| --- | --- |
| `id` | Unique, nonempty string across the combined catalog |
| `direction` | `ClientToServer` or `ServerToClient`; one direction per definition |
| `target` | `None` or `Actor` |
| `mode` | `Latest` or `Pulse` |
| `payload` | Required [bounded schema](./schemas); use an Optional schema when nil is a legal payload |
| `authorize` | Required function for ClientToServer definitions: `(context: HintContext, payload: any) -> (boolean, string?)` |
| `receive` | Required function for ClientToServer definitions: `(context: HintContext, payload: any) -> ()` |

`HintDefinition` and `HintContext` are exported from `server.Networking.types`. The context identifies the Player, resolved optional Actor and hint id. Callback declarations remain server-local. Both callbacks must be non-yielding; authorization must be side-effect free. They are reserved for cosmetic handling, never authoritative gameplay mutation. Supplied callback fields must be functions, including on ServerToClient definitions.

An Actor target identifies the subject of presentation data; awareness alone does not authorize a client to supply it. A ClientToServer authorizer must explicitly decide permission. `Latest` declares sampled latest-value information; `Pulse` declares an independent disposable occurrence. Neither mode is suitable for damage, Resource spending, Tags, Action activation, inventory or progression. Use [Commands](./commands) when correctness depends on a validated request reaching the server.

## Declare a catalog

This catalog accepts a disposable cosmetic sample for the sending Player's associated Actor:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local Schema = require(KRF.shared.Networking.Schema)
local Authorization = require(KRF.server.Networking.HintAuthorization)

local hints: { Types.HintDefinition } = {
	{
		id = "Game.CosmeticLook",
		direction = "ClientToServer",
		target = "Actor",
		mode = "Latest",
		payload = Schema.Struct({ yaw = Schema.U16 }),
		authorize = Authorization.OwnerActor,
		receive = function(context: Types.HintContext, payload: any): ()
			-- Consume payload.yaw for server-local cosmetic presentation only.
		end,
	},
}

return hints
```

Include the catalog as `config.hints` at your existing startup boundary. Omission and an empty array are both valid. Framework and game definitions share the same uniqueness checks; registration does not allocate a feature-specific remote.

## Startup validation and ownership

Startup owns frozen definitions and nested schema metadata independently of the author's tables. Changing those tables afterward cannot alter the catalog or protocol. Id codes are deterministic regardless of declaration order. Bootstrap shares ids, direction, target, mode and payload schemas; it never shares authorization or receive callbacks. Client payload codecs compile before readiness.

Invalid Hint catalogs fail startup with `system = "Hint"`, without publishing partial registries or transport. Failures include `DuplicateHintId`, `HintDirectionInvalid`, `HintTargetInvalid`, `HintModeInvalid`, `HintAuthorizationRequired`, `HintReceiverRequired`, schema-validation reasons and `HintRecordTooLarge`.

Each definition's conservative schema maximum must fit one private unreliable packet budget, including the envelope, hint code, optional Actor handle and Latest sequence allowance. Oversized definitions fail startup rather than relying on compression or fragmentation. The combined domain, command and Hint bootstrap also has one bounded byte budget. These are internal bounds, not game networking-rate settings.

## Send a cosmetic sample

Require `client.Networking.HintRuntime` and call `Send("Game.CosmeticLook", actorView, { yaw = 120 })` with a current, available ActorView. Pass nil for definitions targeting `None`. See [HintRuntime](/api/Networking/hint-runtime) for local failure returns.

A true return means local admission only. Delivery, authorization and callback success are not acknowledged. Do not retry an occurrence to obtain reliability. Latest replaces the unsent sample for the same definition and Actor, and stale or duplicate arrivals are suppressed. Pulse retains independent occurrences only within bounded pending capacity. Either mode can be dropped under pressure. Neither changes Actor revisions, requests recovery, allocates command request ids or automatically relays to other clients.

The server validates framing, definition, connection-local Actor handle and payload before authorization. Callbacks receive a frozen context and schema-owned immutable payload. [HintAuthorization](/api/Networking/hint-authorization) provides `AnyReadyClient` and `OwnerActor`; custom policies must be non-yielding and return true explicitly. Awareness alone does not grant permission. Authorization errors or yields deny the sample; receive errors or yields are isolated from reliable traffic.

Pending work, bytes, attempts and live Latest streams have private bounds. Limits can shed traffic; they do not guarantee admission or delivery fairness. Actor retirement and client teardown discard their pending samples and sequence state. Latest sequences never wrap; an exhausted live stream stops accepting samples until its lifetime ends. Hints use the framework's single unreliable transport, may batch within one bounded packet, and are never fragmented.

## Send to an explicit client

Declare a separate ServerToClient definition, then call `server.Networking.HintRuntime.SendTo(player, hintId, actor, payload)` for each selected recipient. Actor targets use that recipient's awareness mapping; pass nil for None targets. Admission validates direction, target and payload. Receiving a client Hint never automatically forwards it.

On the client, subscribe to `HintRuntime.OnHintReceived` with a callback taking one receipt. Read `receipt.hintId`, `receipt.actorView` and `receipt.payload`; the receipt and decoded payload are immutable. See [HintRuntime](/api/Networking/hint-runtime) for exact signatures and failure returns.

Server Latest samples coalesce separately per definition, target and recipient. Pulse retains bounded independent occurrences. Scheduling gives admitted eligible recipients turns within aggregate work, byte and send limits, after reliable work. Global or local pressure can refuse admission; there is no delivery or admission guarantee.

Unreliable traffic has no ordering relationship with reliable baselines. An Actor Hint may arrive before its view is installed or while it is unavailable; the client drops it without buffering for recovery. Removal, connection closure and teardown clear obsolete sequence metadata. Never depend on a Hint to establish Actor truth or reliably announce lifecycle changes.
