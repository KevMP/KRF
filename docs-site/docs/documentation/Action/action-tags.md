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

For an accepted request, KRF completes the authoritative transaction before any resulting callback runs. The normal transaction and post-commit order is:

1. Commit prepared Resource costs; terminate conflicting owners and clean their remaining `activeTags` contributions; acquire incoming locks, apply incoming `activeTags` followed by `appliedTags` in declaration order, and activate the incoming instance. Resolve final Properties and affected Resources before callbacks.
2. Issue preempted owners' `OnActionInterrupted` signals in sequence-id order, then the incoming `OnActionStarted` signal.
3. Dispatch the resulting Tag events in mutation order, then Property notifications in commit order, then net Resource notifications in Resource-id order.
4. Invoke preempted owners' `onInterrupt` hooks in sequence-id order, then begin incoming `onStart` only if it is still active.

Synchronous mutations from lifecycle or Tag listeners can issue older pending Property notifications before the remaining Tag events, preserving Property commit order. See [Property changes](../Property/property-runtime#changes).

Listeners and hooks may reenter KRF. Nested `RequestAction`, `EndAction`, and `InterruptAction` calls complete synchronously. Started is issued exactly once for every accepted instance, before its terminal signal. If an earlier owner's listener terminates the incoming instance before its normal Started turn, KRF issues its pending Started before that terminal signal. The accepted request still returns its sequence id, and its `onStart` is skipped. Signal issuance does not guarantee that every listener finishes before subsequent signals or hooks.

On End, Interrupt, preemption, update or start failure, and controller destruction, KRF commits all terminal cleanup before callbacks. Normal post-commit dispatch issues terminal lifecycle signals, Tag events, Property notifications, then terminal hooks. `appliedTags` remain under normal Tag lifetime rules. Tag and Property queries read current committed state; earlier reentrant callbacks may already have changed it.

If declarative Tag activation cannot commit, the request returns `ActionTagActivationFailed:<id>` before preempting owners or consuming a sequence id. No incoming locks or Tag effects remain.

Both effect fields use ordinary Tag Runtime rules. Repeated BattleCry requests refresh one `Buff.Courage` instance. With `Stack`, each request would add an instance below the Tag's stack cap; with `Ignore`, an existing instance would be left alone. `maxStacks`, expiry, ticking, Tag events, and Property modifiers follow the Tag definition. An Action never removes another Action's or system's independently owned Tag state during cleanup.

Cleanup removes only state still attributable to that exact ActionInstance. An ignored application owns no new state. Refreshing an existing unrelated record does not make it Action-owned. A later external refresh, including a refresh at `maxStacks`, prevents cleanup from removing that refreshed record; expiry or consumption likewise cannot make cleanup remove a replacement record. Repeated `activeTags` declarations may refresh a record created by that same activation and retain its cleanup ownership. An `appliedTags` refresh of that record relinquishes its active cleanup ownership.

`Status.Dodging` uses `Stack` so concurrent Dodge instances each own their active Tag. Dodge listens to `OnTagRemoved` because this example applies `Status.Grounded` indefinitely. If your Grounded Tag can expire, also listen to `OnTagExpired`. The handler checks current Tag presence because a removed Tag may be reapplied before its event callback runs. `requiredTags` handles the start check; the listener handles a later loss.

## Related

- [Action Registry](./action-registry)
- [Action Runtime](./action-lifecycle)
- [Tag Runtime](../Tags/tag-runtime)
- [ActionController API](/api/Action/action-controller)
