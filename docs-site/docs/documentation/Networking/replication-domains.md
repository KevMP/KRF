---
sidebar_position: 2
---

# Replication domains

A replication domain declares the Actor state and gameplay occurrences your game approves for replication. Your controller owns gameplay; the domain defines its state projection and committed-observation callback contract.

Supply domains through `Server.Init({ replicationDomains = ... })`, separately from controller definitions. Startup publishes the compiled catalog and prepares its schema metadata for the client bootstrap. It does not invoke `snapshot` or `observe` or attach domains to Actors. The [networking handshake](./startup) sends protocol metadata; there is no Actor state or event publication runtime in the current implementation.

## Domain definition {#domain-definition}

Import authored types from `KRF.server.Replication.types`. In the shapes below, `Actor` is `KRF.server.Actor.types.Actor` and `SchemaDefinition` is a definition constructed with [Schema](./schemas).

```lua
export type ReplicationDomainDefinition = {
	id: string,
	state: SchemaDefinition,
	events: { ReplicationEventDefinition }?,
	audience: ReplicationAudience?,
	snapshot: (actor: Actor) -> any,
	observe: ((actor: Actor, onCommitted: ReplicationDomainOnCommitted) -> (() -> ())?)?,
}

export type ReplicationEventDefinition = { id: string, payload: SchemaDefinition }
export type ReplicationAudience = "All" | "Owner"
export type ReplicationDomainEvent = { id: string, payload: any }
export type ReplicationDomainOnCommitted = (events: { ReplicationDomainEvent }?) -> ()
```

| Field | Authoring contract |
| --- | --- |
| `id` | Non-empty string, unique across framework and game domains |
| `state` | Required bounded schema for complete recoverable state |
| `events` | Dense array of `{ id, payload }` definitions; ids are unique within the domain, and payloads have bounded schemas; defaults to empty |
| `audience` | `All` or `Owner` eligibility metadata; defaults to `All` |
| `snapshot` | Required synchronous, non-yielding projection whose result must match `state` |
| `observe` | Optional synchronous adapter accepting the Actor and a committed callback; may return a disconnect function |

Unknown domain and event fields reject startup. Startup validates the schemas and callback types without invoking the callbacks or checking their runtime results. The `any` boundaries above erase Luau payload typing; they do not permit values outside the declared schemas.

## State vs semantic events

| Concept | Meaning | Example |
| --- | --- | --- |
| State | What is true now | `health = 50`, `blocking = false` |
| Semantic event | Something happened | `GuardBroken`, with `{ previousGuard = 20 }` |

`snapshot(actor)` returns the complete current state. A snapshot can recover `health = 50`; it cannot tell you which hits happened earlier. Snapshots do not replay events, and recovery must never require their history.

Declare occurrences separately, with an id and a bounded payload schema:

```lua
events = {
	{ id = "GuardBroken", payload = Schema.Struct({ previousGuard = Schema.F32 }) },
},
```

The committed callback contract represents an occurrence alongside the state notification as:

```lua
onCommitted({
	{ id = "GuardBroken", payload = { previousGuard = 20 } },
})
```

Under this contract, `onCommitted()` reports a mutation with no semantic events. `onCommitted(events)` reports the same state boundary plus ordered occurrences. The domain supplies neither a state patch nor packets. Events are explicit, never inferred from a changed state value.

## Committed-observation callback contract

The dynamic example below shows how to author the stored callbacks. It does not demonstrate an active replication runtime. The callback contract assigns these responsibilities:

1. `observe(actor, onCommitted)` accepts an Actor and a callback supplied by its attachment caller.
2. When invoked, the example adapter subscribes to the controller's private committed observers and returns a disconnect function.
3. After fully committing a mutation, the example controller synchronously calls its registered observers.
4. The adapter calls the supplied `onCommitted()` to report that boundary. Its contract requires the complete state to be available through `snapshot(actor)` without yielding.

The controller never calls Networking. Its observer method belongs to your game; `_observeCommitted` is the name used in this example, not a required KRF controller API. The domain adapts that method to the declared callback signature.

### Controller: own and commit gameplay state

Place both modules below in your server-side `Game` folder. This small controller owns a stamina value, rejects invalid spends, and notifies observers only after a successful spend commits.

```lua title="Game/StaminaController.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)

export type StaminaController = {
	GetCurrent: (self: StaminaController) -> number,
	Spend: (self: StaminaController, amount: number) -> (boolean, string?),
	_observeCommitted: (self: StaminaController, callback: () -> ()) -> (() -> ()),
	Destroy: (self: StaminaController) -> (),
}

local StaminaController = {}

function StaminaController.new(_actor: ActorTypes.Actor): StaminaController
	local controller: StaminaController = {} :: StaminaController
	local current: number = 100
	local destroyed: boolean = false
	local nextObserverId: number = 0
	local observers: { [number]: () -> () } = {}

	function controller:GetCurrent(): number
		return current
	end

	function controller:_observeCommitted(callback: () -> ()): () -> ()
		assert(not destroyed, "StaminaControllerDestroyed")
		nextObserverId += 1
		local observerId: number = nextObserverId
		observers[observerId] = callback
		return function(): ()
			observers[observerId] = nil
		end
	end

	function controller:Spend(amount: number): (boolean, string?)
		if destroyed then
			return false, "StaminaControllerDestroyed"
		end
		if amount ~= amount or amount <= 0 or amount == math.huge then
			return false, "StaminaAmountInvalid"
		end
		if amount > current then
			return false, "StaminaInsufficient"
		end

		current -= amount -- Authoritative mutation is complete before notification.
		for observerId: number, callback: () -> () in table.clone(observers) do
			if observers[observerId] == callback then
				callback() -- Synchronous; do not task.spawn or defer this call.
			end
		end
		-- Dispatch any public gameplay notifications after committed observers.
		return true, nil
	end

	function controller:Destroy(): ()
		destroyed = true
		table.clear(observers)
	end

	return controller
end

return StaminaController
```

### Domain: project state and adapt observation

When invoked, `snapshot` reads the controller without changing it, and `observe` subscribes to that same controller. The returned disconnect function releases the subscription.

```lua title="Game/StaminaReplicationDomain.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Schema = require(KRF.shared.Networking.Schema)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local StaminaController = require(script.Parent.StaminaController)

local domain: ReplicationTypes.ReplicationDomainDefinition = {
	id = "Game.Stamina",
	state = Schema.Struct({ current = Schema.F32 }),
	snapshot = function(actor: ActorTypes.Actor): any
		local controller: StaminaController.StaminaController? =
			actor:GetController("Game.StaminaController") :: StaminaController.StaminaController?
		assert(controller ~= nil, "Game.StaminaController missing")
		return { current = controller:GetCurrent() }
	end,
	observe = function(
		actor: ActorTypes.Actor,
		onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		local controller: StaminaController.StaminaController? =
			actor:GetController("Game.StaminaController") :: StaminaController.StaminaController?
		assert(controller ~= nil, "Game.StaminaController missing")
		return controller:_observeCommitted(function(): ()
			onCommitted()
		end)
	end,
}

return domain
```

### Startup: register the controller and domain

Place this script beside the two modules. A domain id does not need to match a controller key; the callbacks explicitly choose which controller to read.

```lua title="Game/Startup.server.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ServerTypes = require(KRF.server.types)
local StaminaController = require(script.Parent.StaminaController)
local StaminaDomain = require(script.Parent.StaminaReplicationDomain)

local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({
	controllers = { { key = "Game.StaminaController", factory = StaminaController.new } },
	replicationDomains = { StaminaDomain },
})
if not started then
	local detail: string = if failure then failure.system .. ": " .. failure.reason else "Unknown startup failure"
	error(detail)
end
```

This registers the contracts. Catalog loading itself does not install the example's observer or start replication. See [Initializing KRF](../initializing-krf) for startup and [Actor Runtime](/api/Actor/actor-runtime) for creating Actors with registered controllers.

## Rules for authoring callbacks

Commit all state participating in the projection before notifying observers. Call committed observers before public gameplay callbacks can perform reentrant mutations and obscure that boundary.

`snapshot`, observer delivery, and `onCommitted` must be synchronous and non-yielding. Do not defer them to Heartbeat, `task.spawn`, or `task.defer`. An asynchronous Signal cannot preserve this boundary. Capture semantic event payloads from the committed occurrence and pass them before returning; later changes to gameplay tables must not alter that occurrence.

Omit `observe` only for state that remains static for the Actor's lifetime. A changing domain needs an adapter that reports every meaningful committed mutation.

## Audience and ownership

`audience = "All"` means all eligible recipients for that Actor; `"Owner"` means only its owning player is eligible. `All` is the default. Audience does not establish Actor awareness or make every player a recipient.

`snapshot` receives only the Actor, so its result is independent of the recipient. Use separate public and private domains when their projections differ. One domain may read several systems, and a controller may have no domain.

KRF combines framework and game domains before startup validation. Duplicate domain ids, malformed events, invalid schemas or audiences, and missing required callbacks fail before publication. Event ids must be unique within a domain; different domains may reuse an event id.

Successful startup publishes immutable catalog metadata. Source-table edits cannot change the loaded contract; live gameplay state stays in the controller. Games cannot register or replace domains at runtime. Definitions contain semantic fields only: games supply no Remote references, wire ids, byte offsets, revisions, or flush settings.

All clients receive the same domain and event schema catalog during protocol startup, including domains whose audience is `Owner`. The bootstrap excludes the stored server callbacks and live Actor values; audience metadata does not conceal schema definitions.

## Related

- [Bounded schemas](./schemas)
- [Networking startup](./startup)
- [Replication Domain Registry API](/api/Networking/replication-domain-registry)
