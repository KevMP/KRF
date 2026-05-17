# Tag Runtime

`TagController` is KRF's runtime surface for applying and removing tags on a live actor.

`TagRegistry` defines what a tag means. `TagController` answers the next question: which of those tags are active on this actor right now?

Use it when gameplay state changes during runtime. A hit may apply `Status.Stunned`, a sprint input may apply `Buff.Sprint`, and a cleanse may remove one or more active tag instances.

## What this is

An active tag is a runtime instance of a tag definition attached to one actor.

KRF tracks active tags per actor, not globally. Two actors may both have `Status.Stunned`, but each actor owns its own active instances, durations, and stack count.

## What this owns

`TagController` owns:

* applying a registered tag to one actor
* resolving active instance duration from explicit options or the tag definition
* enforcing `Ignore`, `Refresh`, and `Stack` duplicate behavior
* tracking stack count and individual active instances
* removing one active instance or all active instances for a tag id
* firing tag mutation events for runtime observers

## What this does not own

`TagController` does not own:

* defining the tag catalog
* validating tag definitions
* deciding what a tag means in UI, combat, or movement systems
* cross-actor queries

## Canonical flow

The normal flow is:

1. Load tag definitions through `TagRegistry` during startup.
2. Get the actor's `TagController`.
3. Apply or remove tags as gameplay state changes.
4. Query active tags when another system needs current state.
5. Observe tag events if another controller or service reacts to changes.

Reapplying a tag depends on its duplicate behavior:

* `Ignore` keeps the existing active instance and does not create another one.
* `Refresh` keeps one active instance and refreshes its duration.
* `Stack` creates another active instance until `maxStacks` is reached.

If a stacked tag is reapplied at `maxStacks`, KRF refreshes an existing stack instead of creating a new one.

## Removing tags

KRF exposes two different removal intents because stacked tags need both:

* `RemoveTag(tagId)` removes every active instance for that tag id from the actor.
* `RemoveSingleTag(tagId)` removes exactly one active instance for that tag id.

For stacked tags, `RemoveSingleTag` removes the oldest applied active instance first. If only one active instance remains, removing one clears the tag entirely.

If the tag is not active, both removal calls fail with `TagNotActive` and do not fire mutation events.

## Querying active state

There are two common query shapes:

* `HasTag(tagId)` answers whether the actor currently has at least one active instance.
* `GetActiveTags()` returns one entry per active tag id with aggregate `stackCount`.

Use `GetTagInstances(tagId)` when a system needs per-instance details such as duration metadata or applied order for a stacked tag.

## Event contract

`TagController` exposes events for systems that react to runtime tag changes.

Event order is stable:

* a successful add fires `OnTagAdded` and then `OnTagChanged`
* a successful refresh fires `OnTagRefreshed` and then `OnTagChanged`
* a successful removal fires `OnTagRemoved` and then `OnTagChanged`

Failed mutations do not fire these events.

## Example

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)

type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController

local function getTagController(actor: Actor): TagController
	return actor:GetController("TagController") :: TagController
end

local function applySprint(actor: Actor): ()
	local tagController: TagController = getTagController(actor)

	local added: boolean, addReason: string? = tagController:AddTag("Buff.Sprint", {
		duration = 6,
	})

	if not added then
		warn(("Failed to apply sprint buff: %s"):format(addReason or "unknown"))
	end
end

local function consumeOneSprintStack(actor: Actor): ()
	local tagController: TagController = getTagController(actor)
	local removed: boolean, removeReason: string? = tagController:RemoveSingleTag("Buff.Sprint")

	if not removed and removeReason ~= "TagNotActive" then
		warn(("Failed to remove sprint stack: %s"):format(removeReason or "unknown"))
	end
end

local function clearStun(actor: Actor): ()
	local tagController: TagController = getTagController(actor)
	tagController:RemoveTag("Status.Stunned")
end
```

## Common mistakes

* Treating tag definitions as active tag state. `TagRegistry` defines tags, but `TagController` owns per-actor runtime state.
* Using remove-all semantics when only one stack should be consumed. Use `RemoveSingleTag` when the gameplay rule is "spend one stack."
* Expecting `GetActiveTags()` to return one entry per stack instance. It returns one aggregated entry per active tag id.

## Related concepts

Read [Tag Registry](./tag-registry) for the tag catalog and definition rules.

Read [Actor Runtime](../Actor/actor-runtime) for the actor lifecycle that creates and tears down the controllers tags live inside.
