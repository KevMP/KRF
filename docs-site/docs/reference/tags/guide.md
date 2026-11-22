---
title: Tags
---

# Tags

A stun needs to expire, a buff needs to stack, and an ability needs to ask whether the character is Blocking. Tags give those effects a shared identity and lifecycle. Each Actor's TagController tracks its active applications, so the code checking a status doesn't need to know who applied it.

## Define an effect

This Tag halves a registered Property for four seconds:

```lua
local Winded: KRF.TagDefinition = {
	id = "Winded",
	defaultDuration = 4,
	duplicateBehavior = "Refresh",
	visibility = "ClientVisible",
	properties = { StaminaRegen = { multiply = 0.5 } },
}
```

Include the definition in `Server.Init({ tags = ... })` and StaminaRegen in the Property catalog. The modifier affects an Actor only if it has that Property assigned.

```lua
local tags = actor:GetController("TagController") :: KRF.TagController
local added: boolean, reason: string? = tags:AddTag("Winded")
assert(added, reason)
```

The controller resolves the definition's duration when adding the Tag. Passing `{ duration = 2 }` overrides it for that application. Omitting the override uses `defaultDuration`; if both are absent, the instance lasts until removed or the Actor is destroyed.

## Decide what another application means

`Ignore` keeps an existing instance unchanged. `Refresh` replaces its remaining duration with the new application duration; it doesn't add the new duration to the old one. `Stack` creates independent instances, each with its own timer and modifier contribution.

With a stack cap, another application refreshes the instance nearest expiry. Equal remaining durations are resolved by oldest application order; indefinite instances are considered later than finite deadlines. `RemoveSingleTag` instead removes the oldest applied instance, while `RemoveTag` removes every instance of that ID.

Refresh preserves tick progress and original application order. For a definition with no default duration, refreshing without an override can turn a previously timed application into an indefinite one. Passing nil doesn't clear a definition's default.

## Let an Action own a status

Use an Action's `activeTags` when the activation should apply a status and clean up its own application on End or Interrupt. Use `appliedTags` when the status should follow its ordinary duration after the Action ends, such as a regeneration boost from an instant Action.

Duplicate policies still apply. An ignored duplicate gives the Action no new application to clean up. Refreshing an existing application, including at a stack cap, doesn't transfer its ownership to the incoming Action. A later refresh by other code also prevents the original activation from removing that newer version during cleanup.

Use independent Stack applications when effects need independent lifetimes, with enough capacity to create those applications. Removing every stack in a cleanup callback would also remove effects belonging to other callers.

Tags used in `requiredTags` and `blockedTags` are start conditions. Adding Stunned doesn't automatically cancel every running Action. Express an interruption in the game behavior that owns it; there is no shipped combat policy that interprets every status name.

## Timed work and the current tick contract

KRF advances duration and tick countdowns while the Actor is enabled. A due tick runs before expiry in the same pass, and each instance can tick at most once per pass. A delayed pass doesn't replay every missed interval; its next countdown starts from a fresh interval. Stacked instances each have their own countdown and tick callback.

`onTick(actor, deltaTime)` currently receives the controller's triggering step delta, not accumulated time since this instance's previous tick. Automatic advancement uses 0.1-second steps. With `tickInterval = 1`, multiplying a per-second drain by that callback delta undercounts the interval. [Issue #145](https://github.com/KevMP/KRF/issues/145) tracks changing this contract; that change hasn't shipped.

For an effect defined as 3 Qi per scheduled tick, use a fixed amount per callback. Use an Action's elapsed-time `onUpdate` when the effect needs to scale with elapsed time. Keep tick callbacks short and non-yielding: errors are warned and isolated, but a yield can suspend the rest of that advancement pass.

## Notifications and client visibility

Server events distinguish addition, refresh, manual removal and timed expiry. Each application or removal emits its semantic event and `OnTagChanged`; a tick or ordinary countdown decrement alone emits neither. A Tag mutation resolves its affected Properties and dependent Resource configuration before its public notifications.

Events report transitions, while a query reads current state. For example, a Removed event can mean one stack was removed while others remain. Check `HasTag` or the snapshots when a consumer needs to know whether the status is still active.

`ClientVisible` replicates aggregate Tag state and semantic events to every client. Clients use [TagsView](../actors/client-views-api#tagsview), not TagController. Client countdowns are estimates; zero remaining time isn't permission to remove a Tag locally. `ServerOnly` Tags and their IDs remain absent from client state.

See [Tags API](./api), [Properties](../properties/guide) and [Meditate](/tutorial/meditate).
