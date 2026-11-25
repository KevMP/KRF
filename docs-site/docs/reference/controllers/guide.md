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

## Give a Controller events

Other server code may need to know when a character is promoted, such as a quest that unlocks at rank 3 or an announcement in chat. Give the Controller an event the same way KRF's own Controllers do: keep the Signal inside the factory, expose a read-only Event made from it, and destroy the Signals with the Controller.

```lua
export type RankController = KRF.Controller & {
	GetRank: () -> number,
	Promote: () -> (),
	OnPromoted: KRF.Event<number, number>,
}

local Rank: KRF.ControllerDefinition = {
	key = "Rank",
	factory = function(_actor: KRF.Actor): KRF.Controller
		local rank: number = 1
		local promoted: KRF.Signal<number, number> = KRF.Signal.new()
		local ownedSignals: KRF.OwnedSignals = KRF.OwnedSignals.new({ promoted })

		local controller: RankController = {
			GetRank = function(): number
				return rank
			end,
			Promote = function(): ()
				local previousRank: number = rank
				rank += 1

				ownedSignals:WithDeferredDestroy(function(): ()
					promoted:Fire(previousRank, rank)
				end)
			end,
			OnPromoted = KRF.Signal.wrapEvent(promoted),
			Destroy = function(): ()
				ownedSignals:Destroy()
			end,
		}

		return controller
	end,
}
```

A listener receives the previous and new rank:

```lua
local ranks = actor:GetController("Rank") :: RankController

ranks.OnPromoted:Connect(function(previousRank: number, newRank: number): ()
	if previousRank < 3 and newRank >= 3 then
		unlockQuest(actor, "Trial of Flame")
	end
end)
```

Update the state before firing, so a listener that calls `GetRank` sees the new rank. Firing inside `WithDeferredDestroy` matters when a listener ends the Actor's lifetime: teardown calls `Destroy` while the event is still being delivered, and the Signals wait until delivery finishes. Listeners subscribe through `OnPromoted` and can't fire it. See [Events and connections](../getting-started/events#own-events-in-game-code) for the Signal API.

## Publish selected state to clients

A custom Controller remains server-owned. To expose its rank or score, define a [replication domain](../replication/guide) that takes a snapshot and observes committed changes. Client code reads a DomainView, not the server Controller.

The Controller should commit its own state before notifying its replication observer. Separate that private commit notification from public gameplay callbacks so reentrant code can't publish a partly updated state.

See [Controllers API](./api) and [the Cultivation example](/tutorial/break-through).
