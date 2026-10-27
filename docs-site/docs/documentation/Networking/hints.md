---
sidebar_position: 5
---

# Hints

Hints describe disposable, non-authoritative presentation messages. Supply definitions through the `hints` catalog in [server startup](../initializing-krf), then inspect the immutable catalog through [HintRegistry](/api/Networking/hint-registry).

ClientToServer hints support local sending and explicitly authorized server callbacks. ServerToClient hints use explicit recipient sends and a client receipt event. Registering a definition alone sends no Hint traffic.

## Definition fields {#definition-fields}

| Field | Contract |
| --- | --- |
| `id` | Unique, nonempty string across the combined catalog |
| `direction` | `ClientToServer` or `ServerToClient`; one direction per definition |
| `target` | `None` or `Actor` |
| `mode` | `Latest` or `Pulse` |
| `payload` | Required [bounded schema](./schemas); use an Optional schema when nil is a legal payload |
| `authorize` | Required function for ClientToServer definitions: `(context: HintContext, payload: any) -> (boolean, string?)` |
| `receive` | Required function for ClientToServer definitions: `(context: HintContext, payload: any) -> ()` |

`HintDefinition` and `HintContext` are exported from `server.Networking.types`. Context fields are `player: Player`, `actor: Actor?` and `hintId: string`; Actor is nil for None targets. Callback declarations remain server-local. Both callbacks must be non-yielding; authorization must be side-effect free and explicitly return true to allow a sample. They are reserved for cosmetic handling, never authoritative gameplay mutation. Supplied callback fields must be functions, including on ServerToClient definitions; those callbacks do not handle S2C receipts.

An Actor target identifies the subject of presentation data; awareness alone does not authorize a client to supply it. A ClientToServer authorizer must explicitly decide permission. `Latest` declares sampled latest-value information; `Pulse` declares an independent disposable occurrence. Neither mode is suitable for damage, Resource spending, Tags, Action activation, inventory or progression. Use [Commands](./commands) when correctness depends on a validated request reaching the server.

## Declare a catalog

This catalog accepts owner-authorized look samples and defines separate outgoing facing and optional VFX messages. Angles use game-defined quantized units; Networking supplies no aim interpretation.

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
	{
		id = "Game.CosmeticFacing",
		direction = "ServerToClient",
		target = "Actor",
		mode = "Latest",
		payload = Schema.Struct({ yaw = Schema.U16 }),
	},
	{
		id = "Game.OptionalBurst",
		direction = "ServerToClient",
		target = "Actor",
		mode = "Pulse",
		payload = Schema.Struct({ variant = Schema.Enum({ "Spark", "Dust" }) }),
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

An initialized client can call this helper with the selected view and a valid U16 yaw. It does not start a sampling loop or retry refused samples:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.client.Actor.types)
local Hints = require(KRF.client.Networking.HintRuntime)

local function sampleLook(view: ActorTypes.ActorView, yaw: number): boolean
	local admitted = Hints.Send("Game.CosmeticLook", view, { yaw = yaw })
	return admitted
end

return sampleLook
```

A true return means local admission only. Delivery, authorization and callback success are not acknowledged. Do not retry an occurrence to obtain reliability. Latest replaces the unsent sample for the same definition and Actor, and stale or duplicate arrivals are suppressed. Pulse retains independent occurrences only within bounded pending capacity. Either mode can be dropped under pressure. Neither changes Actor revisions, requests recovery, allocates command request ids or automatically relays to other clients.

The server validates framing, definition, connection-local Actor handle and payload before authorization. Callbacks receive a frozen context and schema-owned immutable payload. [HintAuthorization](/api/Networking/hint-authorization) provides `AnyReadyClient` and `OwnerActor`; custom policies must be non-yielding and return true explicitly. Awareness alone does not grant permission. Authorization errors or yields deny the sample; receive errors or yields are isolated from reliable traffic.

Pending work, bytes, attempts and live Latest streams have private bounds. Limits can shed traffic; they do not guarantee admission or delivery fairness. Actor retirement and client teardown discard their pending samples and sequence state. Latest sequences never wrap; an exhausted live stream stops accepting samples until its lifetime ends. Hints use the framework's single unreliable transport, may batch within one bounded packet, and are never fragmented.

The current internal complete-packet ceiling is 900 encoded bytes, including all framing. Startup checks each definition's conservative maximum, not just typical payloads. This is an implementation limit, not a supported payload-size tuning API.

## Send to an explicit client

Declare a separate ServerToClient definition, then call `server.Networking.HintRuntime.SendTo(player, hintId, actor, payload)` for each selected recipient. Actor targets use that recipient's awareness mapping; pass nil for None targets. Admission validates direction, target and payload. Receiving a client Hint never automatically forwards it.

On the client, subscribe to `HintRuntime.OnHintReceived` with a callback taking one receipt. Read `receipt.hintId`, `receipt.actorView` and `receipt.payload`; the receipt and decoded payload are immutable. See [HintRuntime](/api/Networking/hint-runtime) for exact signatures and failure returns.

Server Latest samples coalesce separately per definition, target and recipient. Pulse retains bounded independent occurrences. Scheduling gives admitted eligible recipients turns within aggregate work, byte and send limits, after reliable work. Global or local pressure can refuse admission; there is no delivery or admission guarantee.

Unreliable traffic has no ordering relationship with reliable baselines. An Actor Hint may arrive before its view is installed or while it is unavailable; the client drops it without buffering for recovery. Removal, connection closure and teardown clear obsolete sequence metadata. Never depend on a Hint to establish Actor truth or reliably announce lifecycle changes.

### Latest facing and Pulse VFX

This server helper takes an explicitly selected Player and a registered Actor. Call it from server-owned presentation logic. A refused cosmetic send needs no reliable fallback:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local Hints = require(KRF.server.Networking.HintRuntime)

local function present(player: Player, actor: ActorTypes.Actor, yaw: number): ()
	Hints.SendTo(player, "Game.CosmeticFacing", actor, { yaw = yaw })
	Hints.SendTo(player, "Game.OptionalBurst", actor, { variant = "Spark" })
end

return present
```

On the client, keep effect ownership in the presentation system. The supplied callbacks here are game functions, not KRF APIs; return the disposer to that system's teardown:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Networking.types)
local Hints = require(KRF.client.Networking.HintRuntime)

local function attach(
	face: (ActorTypes.ActorView, number) -> (),
	burst: (ActorTypes.ActorView, string) -> ()
): () -> ()
	local connection = Hints.OnHintReceived:Connect(function(receipt: Types.HintReceived): ()
		local view = receipt.actorView
		if view == nil or not view:IsAvailable() then return end
		-- Payloads are schema-erased; narrow by the known definition id.
		local payload: any = receipt.payload
		if receipt.hintId == "Game.CosmeticFacing" then
			face(view, payload.yaw)
		elseif receipt.hintId == "Game.OptionalBurst" then
			burst(view, payload.variant)
		end
	end)
	return function(): ()
		connection:Disconnect()
	end
end

return attach
```

An effect that persists after the callback must also follow [ActorView removal and unavailability](./actor-views). A missed Pulse must leave no required gameplay or persistent effect waiting for another Hint. Latest is not a queryable cache, and a fresh subscriber receives no replay.

## Prohibited: authoritative Fireball targeting

Do **not** install this as a Hint receiver. Even with a valid schema and OwnerActor authorization, using an unreliable sample to start an authoritative Action makes loss, stale data and refusal affect gameplay:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local ActionTypes = require(KRF.server.Action.types)

local function forbidden(context: Types.HintContext, payload: any): ()
	local actor = context.actor
	if actor == nil then return end
	local actions = actor:GetController("ActionController") :: ActionTypes.ActionController?
	if actions ~= nil then
		-- PROHIBITED: assumes a game-defined Combat.Fireball Action.
		actions:RequestAction("Combat.Fireball", { target = payload.target })
	end
end

return forbidden
```

Carry gameplay targeting in a [Command](./commands), validate it against server truth, and let ActionController apply grants, requirements and declarative costs. Optional facing/VFX Hints may decorate the result; neither hit resolution nor payment may depend on them.

## Related

- [HintRuntime API](/api/Networking/hint-runtime)
- [HintRegistry API and definition contract](/api/Networking/hint-registry)
- [HintAuthorization API](/api/Networking/hint-authorization)
- [Maintainer scheduling and diagnostics](./maintaining-networking)
