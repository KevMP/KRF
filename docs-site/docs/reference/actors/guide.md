---
title: Actors
---

# Actors

Register a character or NPC Model as an Actor when it needs KRF gameplay state. That registration gives the character an identity and Controllers that own its Resources, Tags, Actions and game-specific state. Player characters and NPCs use the same lifecycle.

## Register a Model

After [server initialization](../getting-started/initialization), register the Model and check the result:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(character, {
	properties = { MaxStamina = 150 },
})

if actor == nil then
	warn(`Character registration failed: {reason}`)
	return
end
```

This example assumes a registered `MaxStamina` Property. Initial Property overrides are installed before dependent controller factories, so a Resource that reads MaxStamina sees 150 immediately.

Registration binds identity to the Model, creates Controllers in dependency order and attaches replication. KRF enables the Actor before announcing registration. A reported construction or publication failure tears down the attempted Controllers and removes KRF's binding and publication state. Factory-owned side effects still need cleanup in the Controller's Destroy method.

Successful registration means the Actor lifecycle was installed. It does not guarantee every optional gameplay value was assigned: for example, a failed automatic Resource assignment can warn and leave that Resource absent. Check the relevant Controller when your game requires a particular assignment.

## Follow the character's lifetime

Register each new character Model once. When a player respawns, the new Model gets a new Actor and fresh Controller state. Keep choices or progression that should survive respawns in a separate game-owned player record, then restore them to the new Actor.

```lua
local removed: boolean, reason: string? = KRF.ActorRuntime.UnregisterActor(actor, "CharacterRemoved")
```

Unregistration disables the Actor, detaches replication and destroys its Controllers before removing its Model binding. Destroying the bound Model or setting its Parent to nil also triggers cleanup, with reason `"ModelGone"`. Use explicit unregistration when game logic ends the Actor's lifetime before the Model disappears.

`OnActorUnregistering` occurs after disablement and before Controller teardown. `OnActorUnregistered` occurs after teardown and unbinding. A registration event observes the fully registered Actor. Lifecycle listeners can call back into gameplay, so a listener can also unregister an Actor before the original registration call returns.

## Find existing state

Use `ActorRegistry.GetActorByModel(model)` or `GetActorById(id)` on the server. A missing entry returns `nil`; don't register a second Actor just to perform a lookup.

The server Actor and the client's [ActorView](./client-views) are different objects. The Actor can own mutable controllers. The ActorView exposes the replicated state available to that client and never grants write access to the server Actor.

Add your own per-Actor state through a [Controller](../controllers/guide). Keep Model lifecycle work in the script that registers characters, rather than recreating registration inside every gameplay system.

See [Actors API](./api) and [the tutorial's Cultivation Controller](/tutorial/break-through).
