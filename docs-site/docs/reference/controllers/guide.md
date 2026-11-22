---
title: Controllers
---

# Controllers

Give an Actor its own Controller when it needs game-specific state and behavior. A rank Controller can own that character's progression, while another character has a separate rank. ActorRuntime creates those objects during registration and destroys them during teardown.

## Define an Actor-owned object

Supply a Controller definition to `Server.Init({ controllers = ... })`. Its factory receives the Actor and returns the object that Actor will own:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

export type RankController = KRF.Controller & {
	GetRank: () -> number,
	Promote: () -> (),
}

local Rank: KRF.ControllerDefinition = {
	key = "Rank",
	factory = function(_actor: KRF.Actor): KRF.Controller
		local rank: number = 1
		local controller: RankController = {
			GetRank = function(): number
				return rank
			end,
			Promote = function(): ()
				rank += 1
			end,
			Destroy = function(): () end,
		}

		return controller
	end,
}

return Rank
```

Keep Actor-specific mutable state inside the factory, as `rank` is here. State captured outside it is shared by every object the factory creates. Retrieve the attached object with `actor:GetController("Rank")`; use the game-owned `RankController` type when you need its extra methods.

Put cleanup for the object's connections and scheduled work in `Destroy`. If construction fails before returning the object, release anything the factory already acquired: KRF cannot destroy an object it never received.

Keep both factory and cleanup work synchronous. Yielding can suspend registration or teardown; KRF catches thrown errors but doesn't cancel callbacks that yield.

## Declare construction dependencies

If the factory needs another Controller, name it in `dependsOn`:

```lua
dependsOn = { "PropertyController" },
```

KRF resolves the attachment set before construction. It creates dependencies first, using catalog order to break ties between eligible definitions. When your factory runs, the Actor has its Model bound and the declared dependencies attached; it is not enabled yet.

`autoAttach` defaults to `true`. A missing catalog dependency or cycle rejects startup. Setting a definition's `autoAttach` to `false` leaves it out of automatic construction. If an automatically attached Controller still depends on it, the catalog can load, but Actor registration fails because that dependency is absent from the attachment set. KRF doesn't construct it on demand.

Cleanup has no reverse-dependency order guarantee. Release what the Controller owns without requiring another Controller to remain attached. A thrown Destroy error is warned and teardown continues with the remaining objects.

## Publish selected state to clients

A custom Controller remains server-owned. To expose its rank or score, define a [replication domain](../replication/guide) that takes a snapshot and observes committed changes. Client code reads a DomainView, not the server Controller.

The Controller should commit its own state before notifying its replication observer. Separate that private commit notification from public gameplay callbacks so reentrant code can't publish a partly updated state.

See [Controllers API](./api) and [the Cultivation example](/tutorial/break-through).
