---
title: Properties
---

# Properties

A temporary Defense bonus should disappear cleanly, even when other effects change the same stat. Properties keep an Actor's base number separate from the resolved number gameplay reads after active Tag modifiers.

## Define and assign a stat

Pass a definition through `Server.Init({ properties = ... })`:

```lua
local Defense: KRF.PropertyDefinition = {
	id = "Defense",
	defaultBaseValue = 10,
	autoAssign = true,
}
```

`autoAssign` gives every new Actor the Property at its default, unless registration supplies a different base value. For a stat that only some Actors need, omit it and assign the stat when [registering the Actor](../actors/api#registeractor) or on its first base-value write.

```lua
local properties = actor:GetController("PropertyController") :: KRF.PropertyController
local changed: boolean, reason: string? = properties:SetBaseProperty("Defense", 20)
assert(changed, reason)
```

The ID must already be registered. An unassigned Property returns nil until one of those paths creates its Actor-local record. A [Resource](../resources/guide) that references the Property can also assign it from the definition's default when needed, preserving an existing base value. Applying a Tag modifier alone does not assign the Property.

There is no public unassignment method. Give a respawn its own Actor and Controller state instead of reusing the previous character's PropertyController.

## Read the value gameplay should use

`GetBaseProperty` reads the underlying stat. `GetResolvedProperty` includes buffs and debuffs. Use the resolved value for gameplay that should respect those effects:

```lua
local defense: number? = properties:GetResolvedProperty("Defense")
```

KRF includes WalkSpeed and JumpPower Properties, with defaults of 16 and 50. They store numeric gameplay state. Game-owned movement code must read those values and apply them to the character; changing a Property alone doesn't write a Humanoid field.

## Let Tags modify the stat

A Tag can declare `properties = { Defense = { add = 5 } }`. With a base of 20, one stack resolves Defense to 25; two stacks resolve it to 30. Removing that Tag removes its contribution. Other active modifiers still apply, so your cleanup never has to guess which old value to restore.

Normal resolution adds all `add` contributions, then multiplies all `multiply` contributions, then clamps. Stacks repeat their additions and multiplications. The highest active `min` and lowest active `max` supply the bounds; if those bounds conflict, the final maximum wins because it is applied last.

A `set` modifier takes precedence over that calculation. If several active Tags set the same Property, the lowest set value wins. A single modifier can't combine `set` with normal modifier fields.

## Observe changes at the right level

Subscribe to `OnResolvedPropertyChanged` when a consumer only needs the number used by gameplay. Subscribe to `OnBasePropertyChanged` for changes to the underlying stat, or `OnPropertyChanged` for a record containing both transitions.

With KRF's built-in Controllers, Tag changes recompute affected Properties and dependent Resources before public notifications. A no-op write emits no change event. During reentrant changes, event payloads retain their original transition while queries read the newest installed state.

Properties aren't replicated as a general client stat table. Expose selected game state through a [domain](../replication/guide); clients already get Resource bounds through ResourcesView when a Resource is visible.

See [Properties API](./api) and [Gather Qi](/tutorial/gather-qi).
