# Actors and Controllers

An Actor is one character's lifetime in KRF. Every Tag, Resource, Property value and Action belongs to an Actor, so a character has to be registered before it can take part in gameplay. Controllers are the objects an Actor owns: KRF attaches its own for Tags, Resources, Properties and Actions, and the game can add Controllers for state those don't describe.

## Actors

### Register each character Model once

Register a Model on the server with `KRF.ActorRuntime.RegisterActor(model, options?)`, and check the result. Players and NPCs register the same way. A game created with `create-krf` already registers player characters in `src/server/PlayerActors.luau`; register NPCs yourself when you spawn them.

```lua
local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(npcModel, {
	properties = { MaxHealth = 200 },
})

if actor == nil then
	warn(`Could not register {npcModel.Name}: {reason}`)
	return
end
```

`properties` sets initial Property base values for this Actor. They are installed before the other Controllers are built, so a Resource whose maximum reads `MaxHealth` starts at 200.

### A respawn is a new Actor

Each new character Model gets a new Actor with fresh state. Nothing carries over from the previous Actor. Keep anything that should survive a respawn, such as level or unlocked abilities, in a game-owned record keyed by the player, and restore it to the new Actor after registering it.

An Actor ends when the game calls `KRF.ActorRuntime.UnregisterActor(actor, reason)` or when its Model is destroyed or loses its parent. Unregister explicitly when gameplay ends the Actor before the Model goes away, for example when a downed NPC should stop acting but its body stays.

### Find an existing Actor

Look Actors up with `KRF.ActorRegistry.GetActorByModel(model)` or `GetActorById(id)`. Both return `nil` when there's no Actor. Never register a Model just to get its Actor: that creates a second lifetime.

A common case is hit detection. Game code finds the Model that was hit, looks up its Actor, and changes it through that Actor's Controllers.

### Get a Controller

```lua
local tags = actor:GetController("TagController") :: KRF.TagController
```

The built-in keys are `PropertyController`, `TagController`, `ResourceController` and `ActionController`. A game Controller is retrieved by the key in its definition.

## Controllers

### Decide whether you need one

Write a Controller only for per-character state that no primitive describes, such as a rank, a faction or an inventory. Check the primitives first: a cooldown or charge is a Resource, a temporary status is a Tag, and a stat is a Property.

### Generate it

```bash
npm run createController -- --name Rank --yes --json
```

Pass `--depends-on <key>` once for each Controller the factory uses, and `--no-auto-attach` when only some Actors should get it. See [generators.md](generators.md#createcontroller).

### Fill in the factory

The factory runs once per Actor and returns the object that Actor owns:

```lua
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

Follow these rules:

- Keep per-Actor state in locals inside the factory, as `rank` is here. Anything declared outside the factory is shared by every Actor.
- Disconnect connections and cancel scheduled work in `Destroy`. If the factory fails partway, release what it already acquired before throwing, because KRF never receives an object to destroy.
- Keep the factory and `Destroy` synchronous. A yield stalls registration or teardown.
- List every Controller the factory uses in `dependsOn`. KRF builds those first. The Actor isn't enabled yet while the factory runs.
- Don't rely on another Controller still existing in `Destroy`. Teardown order isn't guaranteed.

### Give it events

When other server code needs to react to a Controller, give it events the way KRF's own Controllers do. Don't use BindableEvents, another signal library or a list of callbacks.

- Create each Signal in the factory with `KRF.Signal.new()`, and group them with `KRF.OwnedSignals.new({ ... })`.
- Expose only `KRF.Signal.wrapEvent(signal)` on the Controller, typed `KRF.Event<...>`, named for what happened, like KRF's own events: `OnPromoted`. Listeners can connect but never fire.
- Update the state first, then fire inside `ownedSignals:WithDeferredDestroy(...)`, so a listener that ends the Actor's lifetime can't destroy the Signals mid-delivery.
- Call `ownedSignals:Destroy()` in the Controller's `Destroy`.

The [Controllers guide](docs/controllers/guide.md#give-a-controller-events) has the full Rank example, and [Events and connections](docs/getting-started/events.md#own-events-in-game-code) has the Signal API.

### Let clients see it

A Controller lives on the server only. To show its state to clients, publish it with a replication domain and read it through a DomainView. See [replication.md](replication.md).

## Exact APIs

- [Actors guide](docs/actors/guide.md) and [Actors API](docs/actors/api.md): registration options, lifecycle events and failure reasons.
- [Controllers guide](docs/controllers/guide.md) and [Controllers API](docs/controllers/api.md): definition fields, dependency resolution and startup errors.

## Related references

- [properties.md](properties.md), [tags.md](tags.md) and [resources.md](resources.md) for the state the built-in Controllers own.
- [replication.md](replication.md) for publishing a game Controller's state.
- [client-views.md](client-views.md) for what clients see of an Actor.
