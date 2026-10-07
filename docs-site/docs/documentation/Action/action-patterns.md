---
sidebar_position: 9
---

# Action Patterns / Recipes

These factories show the Action lifecycle for common gameplay intents. Register factories and their referenced Tags/Resources with `Server.Init`, as shown in the [overview](./actions-overview). The recipes focus on authored behavior; input integration is outside this guide.

Use these imports for the factory snippets below:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
local ResourceTypes = require(KRF.server.Resource.types)
```

Comments mark where game combat, movement, or presentation code belongs. They are not additional KRF APIs. Each recipe is independent.

## Instant Action {#instant-action}

An instant Action explicitly Ends after its accepted work. The request remains accepted even though no activation remains active when it returns.

```lua
local function createInteract(): ActionTypes.ActionDefinition
	return {
		id = "Action.Interact",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(ctx: ActionTypes.ActionExecutionContext): ()
			-- Perform the validated interaction here.
			ctx:End()
		end,
	}
end
```

Use `onCanStart` for a non-yielding game-specific target decision when needed. Validate client-originated parameters before the request. Returning from `onStart` alone would leave this Action active.

## Held / charged Action {#held-charged-action}

Keep charge progress local to the factory. Stop means release intent; this Action chooses normal completion on release.

```lua
local function createCharge(): ActionTypes.ActionDefinition
	local chargeSeconds: number = 0
	return {
		id = "Action.Charge",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Hands" },
		onUpdate = function(_ctx: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			chargeSeconds = math.min(chargeSeconds + deltaTime, 2)
		end,
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext): ()
			-- Use chargeSeconds to determine the release outcome.
			print(`Released at charge {chargeSeconds / 2}`)
			ctx:End()
		end,
	}
end
```

`onStopRequested` handles release intent delivered to this activation. An Interrupt cancels without invoking the release hook. If release needs a recovery period, record a local phase and End later from `onUpdate` instead. Exact Stop delivery semantics are in [Action Lifecycle](./action-lifecycle#stop-end-and-interrupt).

## Channel {#channel}

A channel does ongoing work and completes when its local timer reaches an outcome. Add declarative `costs` for any startup payment; use direct Resource methods for ongoing or hit-dependent payment.

```lua
local function createChannel(): ActionTypes.ActionDefinition
	local remainingSeconds: number = 3
	return {
		id = "Action.Channel",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Hands" },
		onUpdate = function(ctx: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			remainingSeconds -= deltaTime
			-- Apply this update's channel work here while still active.
			if remainingSeconds <= 0 then
				ctx:End()
			end
		end,
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext): ()
			ctx:Interrupt("ChannelCancelled")
		end,
	}
end
```

Put completion-only outcomes in `onEnd` and cancellation cleanup in `onInterrupt`. Both must be non-yielding. Connect any game-owned listeners in `onStart` and disconnect them in both terminal hooks.

## Sprint {#sprint}

Sprint publishes a temporary speed modifier, holds Movement, and pays Stamina per elapsed second. This example uses full `Spend`: if an entire update's payment is unavailable, sprint Ends without partial payment.

```lua
local function createSprint(): ActionTypes.ActionDefinition
	return {
		id = "Action.Sprint",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Movement" },
		activeTags = { "Buff.Sprint" },
		resourceRequirements = { ["Resource.Stamina"] = { min = 1 } },
		onUpdate = function(ctx: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			local resources = ctx.actor:GetController("ResourceController") :: ResourceTypes.ResourceController
			local paid, reason = resources:Spend("Resource.Stamina", 10 * deltaTime)
			if not ctx:IsActive() then
				return
			end
			if not paid then
				if reason ~= "InsufficientResourceValue" then
					warn(`Sprint payment failed: {reason}`)
				end
				ctx:End()
				return
			end
		end,
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext): ()
			ctx:End()
		end,
	}
end
```

Include these definitions in the startup `tags` and `resources` arrays:

```lua
-- Tag definition
{ id = "Buff.Sprint", visibility = "ServerOnly", duplicateBehavior = "Stack",
	properties = { WalkSpeed = { multiply = 1.5 } } }
-- Resource definition
{ id = "Resource.Stamina", visibility = "ServerOnly", autoAssign = true,
	max = { value = 100 } }
```

Game movement code consumes resolved `WalkSpeed`; KRF's numeric Property alone does not move a Humanoid. KRF removes Sprint's remaining active Tag contribution on termination. If exhaustion should consume the final partial amount, use `Drain` and check current value against the minimum instead. Keep regeneration policy in the Resource definition/game logic.

To permit Dodge preemption, add `interruptibleBy = { "Action.Dodge" }` to Sprint and register a Dodge holding Movement.

## Mode / transformation {#mode-transformation}

A mode is a long-lived Action with active modifiers and an explicit exit. It can remain active without `onStart` or recurring updates.

```lua
local function createPowerMode(): ActionTypes.ActionDefinition
	return {
		id = "Action.PowerMode",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Mode" },
		activeTags = { "Mode.Power" },
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext): ()
			ctx:End()
		end,
	}
end
```

Register `Mode.Power` as an indefinite Tag, for example with `duplicateBehavior = "Stack"` and `properties = { WalkSpeed = { add = 4 } }`. The Mode lock prevents a second activation from stacking this mode. Other Actions can run alongside it if their locks do not conflict. Route toggle-off intent to the stored sequence id's Stop request; another start request is not an implicit toggle.

## Cooldown {#cooldown}

Represent readiness with a Resource whose full capacity is consumed on acceptance:

```lua
-- Resource definition in Server.Init's resources array.
{ id = "Cooldown.Burst", visibility = "ServerOnly", autoAssign = true,
	max = { value = 1 }, regen = { rate = { value = 0.2 } } }
```

```lua
local function createBurst(): ActionTypes.ActionDefinition
	return {
		id = "Action.Burst",
		visibility = "ServerOnly",
		autoGrant = true,
		resourceRequirements = { ["Cooldown.Burst"] = { minPercent = 1 } },
		costs = { ["Cooldown.Burst"] = { percent = 1 } },
		onStart = function(ctx: ActionTypes.ActionExecutionContext): ()
			-- Perform the accepted burst here.
			ctx:End()
		end,
	}
end
```

The default minimum is `0` and initial value is maximum. Acceptance empties the meter; regeneration replenishes one unit over approximately five seconds of enabled-Actor stepping. Read current/max through `ResourceController` for UI. Sharing this Resource shares cooldown readiness. Interruption does not refund it.

This begins cooldown at acceptance. For an outcome-dependent cooldown or one beginning only on completion, implement that policy with direct Resource operations; it is a different payment time from declarative `costs`.

## Charges {#charges}

A charge Resource can use capacity `3` and regeneration of one charge per ten seconds:

```lua
-- Resource definition in Server.Init's resources array.
{ id = "Charges.Blink", visibility = "ServerOnly", autoAssign = true,
	max = { value = 3 }, regen = { rate = { value = 0.1 } } }
```

```lua
local function createBlink(): ActionTypes.ActionDefinition
	return {
		id = "Action.Blink",
		visibility = "ServerOnly",
		autoGrant = true,
		resourceRequirements = { ["Charges.Blink"] = { min = 1 } },
		costs = { ["Charges.Blink"] = 1 },
		onStart = function(ctx: ActionTypes.ActionExecutionContext): ()
			-- Perform the validated blink here.
			ctx:End()
		end,
	}
end
```

Resources regenerate continuously and may have fractional current values; a charge becomes usable at `1`, with available whole charges given by `math.floor(current)`. This is a shared continuously refilling pool, not independent per-charge timers. If discrete restoration is required, omit regeneration and call `Restore` from game-owned outcomes or timing logic.

See [Action Resources](./action-resources) for pricing and no-refund guarantees, and [Advanced Ordering & Reentrancy](./action-ordering) when callbacks call back into KRF.
