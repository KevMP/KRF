# Tags

A Tag is a status on an Actor, such as Stunned, Burning or Blocking. A Tag can last for a set time, stack, run code on a timer and modify Properties. When a Tag goes away, everything it changed goes with it.

## Define a status

Pass the duration, duplicate behavior, visibility and modifiers to the generator:

```bash
npm run createTag -- --name Slowed --duration 3 --duplicate-behavior Refresh --visibility ClientVisible --property WalkSpeed:multiply=0.5 --yes --json
```

- **Duration:** omit `--duration` for a Tag that lasts until something removes it, such as Blocking.
- **Duplicate behavior:** decides what applying the Tag again does.
  - `Ignore`, the default, keeps the existing one.
  - `Refresh` restarts its duration. It doesn't add the two durations together.
  - `Stack` adds an independent instance with its own timer and its own modifier contribution. Use `--max-stacks` to cap it.
- **Visibility:** `ClientVisible` sends the Tag to every client, and `ServerOnly` keeps it on the server. Choose `ClientVisible` when the player's UI or effects need to know about it.

For every flag and how to read the result, see [generators.md](generators.md#createtag).

## Modify Properties

Each `--property` adds one modifier. Repeat the flag for more, and combine operations with commas: `--property WalkSpeed:multiply=0.5,min=4`. Every Property a modifier names must already be defined. See [properties.md](properties.md).

All `add` modifiers apply first, then all `multiply` modifiers, then the bounds: the highest `min` and the lowest `max`. Each stack repeats its add and multiply. A `set` modifier overrides all of that, and when several are active the lowest set wins. A modifier with `set` can't contain any other operation.

A modifier only changes the Property's resolved value. KRF never writes Humanoid fields, so a Tag that changes `WalkSpeed` or `JumpPower` does nothing to movement until game code applies the resolved value. See [properties.md](properties.md#apply-movement-properties-yourself).

## Apply a Tag to the right Actor

An Action's `activeTags` and `appliedTags` apply to the Actor running the Action. Use them for the caster's own state:

- `activeTags`, such as Casting, are removed when the Action ends or is interrupted.
- `appliedTags`, such as a regeneration boost, run out on their own duration.

To affect anyone else, such as the target a Fireball hits, look up that target's Actor and add the Tag through its TagController:

```lua
local target: KRF.Actor? = KRF.ActorRegistry.GetActorByModel(hitModel)

if target == nil then
	return
end

local targetTags = target:GetController("TagController") :: KRF.TagController
local added: boolean, reason: string? = targetTags:AddTag("Burning")

if not added then
	warn(`Could not apply Burning: {reason}`)
end
```

`AddTag("Burning", { duration = 2 })` overrides the duration for that one application. `RemoveTag` removes every instance of a Tag. `RemoveSingleTag` removes only the oldest one.

## Tick a damage-over-time effect

Generate the Tag with `--tick-interval 1`, then fill in `onTick`. Deal a fixed amount on each tick:

```lua
onTick = function(actor: KRF.Actor, _deltaTime: number): ()
	local resources = actor:GetController("ResourceController") :: KRF.ResourceController
	resources:Drain("Health", 3)
end,
```

Don't multiply by `deltaTime`. In this KRF version it's the 0.1-second step that made the tick due, not the time since the last tick. Keep `onTick` short, and never yield in it.

## A Tag doesn't act on its own

A Tag does three things: it marks the Actor, modifies Properties and runs `onTick`. Anything else has to come from code that checks for it.

- Actions check Tags only when they start, through `requiredTags` and `blockedTags`. Adding Stunned doesn't cancel an Action that's already running. If a stun should interrupt, write that in the code that applies the stun.
- Other gameplay asks `tags:HasTag("Blocking")` when it needs to know.

## React to Tag changes

TagController fires `OnTagAdded`, `OnTagRefreshed`, `OnTagRemoved` and `OnTagExpired`, each followed by `OnTagChanged`. These events report what happened. A Removed event can fire when one stack ends while others remain. Call `HasTag` when you need to know whether the status is still active.

Clients read `ClientVisible` Tags through the Actor's TagsView. See [client-views.md](client-views.md).

## Exact APIs

- [Tags guide](docs/tags/guide.md) and [Tags API](docs/tags/api.md): definition fields, duplicate rules, tick timing, events and failure reasons.

## Related references

- [properties.md](properties.md) for the stats Tag modifiers change.
- [actions.md](actions.md) for `activeTags`, `appliedTags`, `requiredTags` and `blockedTags`.
- [actors-and-controllers.md](actors-and-controllers.md) for looking up a target's Actor.
- [client-views.md](client-views.md) for showing Tags in the client UI.
