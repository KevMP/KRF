---
sidebar_position: 5
---

# Hint definitions

Hints describe disposable, non-authoritative presentation messages. Supply definitions through the `hints` catalog in [server startup](../initializing-krf), then inspect the immutable catalog through [HintRegistry](/api/Networking/hint-registry).

This branch supports registration, schema validation and protocol bootstrap. Hint sending, receiving, coalescing and delivery events are not installed yet. Registering a definition does not invoke its callbacks or send traffic.

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

This module declares a server-originated cosmetic cue without exposing transport details:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local Schema = require(KRF.shared.Networking.Schema)

local hints: { Types.HintDefinition } = {
	{
		id = "Game.CosmeticBurst",
		direction = "ServerToClient",
		target = "Actor",
		mode = "Pulse",
		payload = Schema.Struct({ style = Schema.Enum({ "Dust", "Spark" }) }),
	},
}

return hints
```

Include the catalog as `config.hints` at your existing startup boundary. Omission and an empty array are both valid. Framework and game definitions share the same uniqueness checks; registration does not allocate a feature-specific remote.

## Startup validation and ownership

Startup owns frozen definitions and nested schema metadata independently of the author's tables. Changing those tables afterward cannot alter the catalog or protocol. Id codes are deterministic regardless of declaration order. Bootstrap shares ids, direction, target, mode and payload schemas; it never shares authorization or receive callbacks. Client payload codecs compile before readiness.

Invalid Hint catalogs fail startup with `system = "Hint"`, without publishing partial registries or transport. Failures include `DuplicateHintId`, `HintDirectionInvalid`, `HintTargetInvalid`, `HintModeInvalid`, `HintAuthorizationRequired`, `HintReceiverRequired`, schema-validation reasons and `HintRecordTooLarge`.

Each definition's conservative schema maximum must fit one private unreliable packet budget, including the envelope, hint code, optional Actor handle and Latest sequence allowance. Oversized definitions fail startup rather than relying on compression or fragmentation. The combined domain, command and Hint bootstrap also has one bounded byte budget. These are internal bounds, not game networking-rate settings.
