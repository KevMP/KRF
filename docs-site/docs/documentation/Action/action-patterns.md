---
sidebar_position: 9
---

# Action Patterns / Recipes

These factories show the Action lifecycle for common gameplay intents. Add factories and their referenced Tags/Resources to the [game catalogs](../initializing-krf). The recipes focus on authored behavior; input integration is outside this guide.

Use these imports for the factory snippets below:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
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

Use `onCanStart` for a non-yielding game-specific target decision when needed. Returning from `onStart` alone would leave this Action active.

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

A channel does ongoing work and completes when its local timer reaches an outcome. Declare acceptance-time payment in `costs`; it is charged once, not each update.

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
