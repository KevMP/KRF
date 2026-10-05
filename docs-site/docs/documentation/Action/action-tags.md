---
sidebar_position: 6
---

# Action Tags

Actions can check an Actor's current Tags before starting and apply Tags when they activate. `ActionController` owns the request and lifecycle; the Actor's `TagController` owns Tag behavior, duration, stacks, events, and Property modifiers.

| Field | Meaning |
| --- | --- |
| `requiredTags` | Every listed Tag must be present when `RequestAction` starts and at final validation. |
| `blockedTags` | Every listed Tag must be absent at those same checks. |
| `activeTags` | Tags applied when the Action starts. KRF removes any Tag state it still owns when the Action ends or is interrupted. |
| `appliedTags` | Tags added when the Action starts. They follow the standard Tag lifecycle, even after the Action ends or is interrupted. |

All four fields refer to Tags on the Action's owning Actor. To affect another Actor, call that Actor's `TagController` explicitly from gameplay code.

## Declare start requirements and effects

This startup example defines two Actions. Dodge requires `Status.Grounded`, blocks `Status.Stunned`, and applies `Status.Dodging` while active. BattleCry applies a timed `Buff.Courage` Tag to its own Actor; the buff follows the normal Tag lifecycle after BattleCry ends. Assume game code applies `Status.Grounded` without a duration; Dodge listens for its removal after starting.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local SignalTypes = require(KRF.shared.Signal.types)

local function createDodge(): ActionTypes.ActionDefinition
	local removedConnection: SignalTypes.Connection? = nil

	local function disconnect()
		if removedConnection ~= nil then
			removedConnection:Disconnect()
			removedConnection = nil
		end
	end

	return {
		id = "Action.Dodge",
		visibility = "ServerOnly",
		autoGrant = true,
		requiredTags = { "Status.Grounded" },
		blockedTags = { "Status.Stunned" },
		activeTags = { "Status.Dodging" },
		onStart = function(ctx)
			local tags = ctx.actor:GetController("TagController") :: TagTypes.TagController
			removedConnection = tags.OnTagRemoved:Connect(function(_actor: ActorTypes.Actor, tagId: string)
				if tagId == "Status.Grounded" and ctx:IsActive() and not tags:HasTag(tagId) then
					ctx:Interrupt("LostGrounded")
				end
			end)
		end,
		onStopRequested = function(ctx)
			ctx:End()
		end,
		onEnd = function(_ctx)
			disconnect()
		end,
		onInterrupt = function(_ctx, _reason)
			disconnect()
		end,
	}
end

local function createBattleCry(): ActionTypes.ActionDefinition
	return {
		id = "Action.BattleCry",
		visibility = "ServerOnly",
		autoGrant = true,
		appliedTags = { { id = "Buff.Courage", duration = 6 } },
		onStart = function(ctx)
			ctx:End()
		end,
	}
end

local started: boolean, failure: Server.StartupFailure? = Server.Init({
	tags = {
		{ id = "Status.Grounded", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
		{ id = "Status.Stunned", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
		{ id = "Status.Dodging", visibility = "ServerOnly", duplicateBehavior = "Stack" },
		{ id = "Buff.Courage", visibility = "ServerOnly", duplicateBehavior = "Refresh" },
	},
	actions = { createDodge, createBattleCry },
})
if not started then
	assert(failure ~= nil)
	error(`KRF startup failed: {failure.system}: {failure.reason}`)
end
```

Each application can be a Tag id string or `{ id = "Tag.Id", duration = seconds }`. Omit `duration` to use the Tag definition's default; without either duration, the application is indefinite. An explicit duration must be finite and greater than zero. Startup rejects unknown Tag ids and invalid entries. Loaded applications are frozen copies in declaration order.

## Request and lifecycle behavior

KRF checks `requiredTags` and `blockedTags` before `onCanStart` and rechecks them after decision work, before activation. A missing required Tag returns `ActionRequiredTagMissing:<id>`; a present blocked Tag returns `ActionBlockedTagPresent:<id>`. The check uses current Tag state, even when preemption could remove a blocking Action's Tag later. A rejected request consumes no sequence id.

For an accepted request, KRF commits lock ownership, all declarative Tag effects, and the incoming Action before Tag or Action callbacks run. `OnActionStarted` and `onStart` see the committed Tags. On End, Interrupt, preemption, update or start failure, and controller destruction, KRF cleans remaining `activeTags` contributions before terminal callbacks. It leaves `appliedTags` alone.

Both effect fields use ordinary Tag Runtime rules. Repeated BattleCry requests refresh one `Buff.Courage` instance. With `Stack`, each request would add an instance below the Tag's stack cap; with `Ignore`, an existing instance would be left alone. `maxStacks`, expiry, ticking, Tag events, and Property modifiers follow the Tag definition. An Action never removes another Action's or system's independently owned Tag state during cleanup.

`Status.Dodging` uses `Stack` so concurrent Dodge instances each own their active Tag. Dodge listens to `OnTagRemoved` because this example applies `Status.Grounded` indefinitely. If your Grounded Tag can expire, also listen to `OnTagExpired`. The handler checks current Tag presence because a removed Tag may be reapplied before its event callback runs. `requiredTags` handles the start check; the listener handles a later loss.

## Related

- [Action Registry](./action-registry)
- [Action Runtime](./action-lifecycle)
- [Tag Runtime](../Tags/tag-runtime)
- [ActionController API](/api/Action/action-controller)
