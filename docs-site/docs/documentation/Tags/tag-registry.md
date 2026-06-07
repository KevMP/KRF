# Tag Registry

`TagRegistry` is KRF's catalog for tag definitions.

Tags give KRF a shared language for gameplay state. They let different systems agree on what something means without each system inventing separate flags, timers, or modifier rules.

Common examples include crowd control such as `Status.Stunned`, movement buffs such as `Buff.Sprint`, or ticking damage effects such as `Status.OnFire`.

A tag definition is not an active tag on an actor. It is the static definition KRF uses to understand what that tag means.

## How tags fit into KRF

Tags are meant to be reusable gameplay signals.

Multiple systems may care about the same state at the same time. A stun may affect movement, input, animation, action gating, or UI. A sprint buff may affect movement resolution and status display. A fire effect may carry both timing metadata and periodic behavior.

`TagRegistry` gives those systems one shared source of truth.

## Loading a tag catalog

Games define their tag catalog in data and load it once during startup.

Load rules:

* load happens once during startup
* load is all or nothing
* invalid catalogs do not partially register
* successful load freezes the catalog for the lifetime of the server
* a second successful load is not supported

## What a tag definition describes

A tag definition gives KRF the static meaning of a tag.

That meaning usually falls into a few buckets:

* **identity**, through a unique tag id
* **reapplication rules**, through stack, refresh, or ignore behavior
* **visibility**, through whether the tag is server only or may be surfaced to clients
* **timing metadata**, such as default duration or tick cadence
* **behavior surfaces**, such as `onTick`
* **numeric modifiers**, through built in or custom properties

Not every tag uses every part of that surface.

A stun may define duration and movement overrides. A sprint buff may define movement modifiers. A ticking damage effect may define duration, tick cadence, and periodic behavior. It may also tick indefinitely when it has `tickInterval` and `onTick` but no duration.

KRF keeps those definitions in one catalog so the rest of the runtime can reason about them consistently.

`TagRegistry` only defines that timing metadata. The live countdown and expiry behavior belongs to `TagController` at runtime.

If a tag uses `onTick`, treat it like lightweight gameplay logic. KRF runs it synchronously during tag stepping, so avoid slow work or yielding there.

## Property modifier modes

A property entry affects a numeric property in one of two ways.

### Override mode

Override mode uses `set`.

If `set` is present, it may not be combined with `add`, `multiply`, `min`, or `max`.

### Normal modifier mode

Normal modifier mode may use any subset of:

* `add`
* `multiply`
* `min`
* `max`

KRF owns these resolution rules. Consumers do not provide custom modifier ordering or cross tag priority.

## Numeric property resolution

* if any active `set` exists, the property resolves through override mode
* if multiple active `set` values exist, the lowest `set` value wins
* otherwise, the property resolves through normal modifier mode
* normal modifier mode resolves as base value plus summed `add`, then multiplied by all `multiply`, then clamped by effective `min` and `max`

Clamp rules:

* effective `min` is the highest active `min`
* effective `max` is the lowest active `max`

## Custom properties

`TagRegistry` also supports custom numeric properties inside `properties`.

This lets games define shared modifier language beyond KRF's built in movement properties. For example, a game may use tag properties for things like `PoiseDamageTaken`, `BlockMeterRegen`, or `DashCostMultiplier`.

The registry validates the modifier shape for these properties the same way it does for built in ones. What a custom property means, and which systems respond to it, is defined by the rest of the game or framework runtime.

Read [Property Runtime](../Property/property-runtime) for the actor-side property surface that owns those numeric values at runtime.

## Related concepts

`TagRegistry` defines tag meaning. `TagController` owns active tag state on a live actor.

Read [Tag Runtime](./tag-runtime) when you need to apply, refresh, stack, query, or remove tags during gameplay.

## Example catalog

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TagRegistry = require(ReplicatedStorage.Packages.KRF.server.Tag.TagRegistry)
local TagTypes = require(ReplicatedStorage.Packages.KRF.server.Tag.types)
local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)

local TagDefinitions: { TagTypes.TagDefinition } = {
	{
		id = "Status.Stunned",
		defaultDuration = 1.5,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				set = 0,
			},
			JumpPower = {
				set = 0,
			},
		},
	},
	{
		id = "Buff.Sprint",
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				add = 6,
				multiply = 1.15,
				max = 32,
			},
			DashCostMultiplier = {
				multiply = 0.8,
			},
		},
	},
	{
		id = "Status.OnFire",
		defaultDuration = 5,
		tickInterval = 1,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		onTick = function(actor: ActorTypes.Actor, _deltaTime: number): ()
			print(actor)
		end,
		properties = {
			HealingReceived = {
				multiply = 0.75,
			},
		},
	},
}
```
