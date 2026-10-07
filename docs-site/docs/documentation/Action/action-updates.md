---
sidebar_position: 8
---

# Action Updates

Define `onUpdate(ctx, deltaTime)` for recurring server work while an Action is active. Each activation uses its own factory callbacks and lexical state; the startup callback is never used for stepping.

## Advance by elapsed time

KRF checks Heartbeat and dispatches at most one update pass per `0.05` seconds (20 Hz). It does not run catch-up passes after a stall. `deltaTime` is finite positive elapsed seconds from activation to the first update, then from the beginning of the previous invocation to the next.

Use the supplied delta for charge progress, channel timing, or ongoing payment. It may exceed `0.05`; this is not a render or physics callback.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)

local function createChannel(): ActionTypes.ActionDefinition
	local elapsedSeconds: number = 0
	return {
		id = "Action.Channel",
		visibility = "ServerOnly",
		autoGrant = true,
		onUpdate = function(ctx: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			elapsedSeconds += deltaTime
			if elapsedSeconds >= 2 then
				ctx:End()
			end
		end,
	}
end
```

Register `createChannel` with `Server.Init({ actions = { createChannel } })`, as in the [overview](./actions-overview). KRF invokes its update callback while the activation is active. Returning from an update leaves it active unless it explicitly Ends or Interrupts.

## Keep updates synchronous

`onUpdate` must not yield, including through `task.wait` or `Event:Wait`. KRF contains errors/yields, cancels a yielded invocation, and Interrupts the still-active activation once with `ActionUpdateFailed`. Other Actions keep updating. An update that already terminated itself does not cause a second terminal transition.

Keep work bounded. After calling another operation that can invoke listeners, check `ctx:IsActive()` before continuing. Direct Resource payment belongs here when it is ongoing; static `costs` are charged only on acceptance. See [channel and sprint recipes](./action-patterns#channel).

## Membership changes

An Action without `onUpdate` has no recurring Action callback work. It can wait in `onStart` or react to Stop/game events instead. Termination removes update membership before terminal callbacks.

KRF snapshots eligible activations before each pass: starts during the pass wait for a later pass, and activations terminated before their turn are skipped. The exact within-Actor order and cross-Actor snapshot guarantee are documented in [advanced ordering](./action-ordering#update-passes).

When the last update-enabled activation terminates, the scheduler disconnects and clears accumulated time. Later work starts a fresh interval.

Next: [Action Patterns / Recipes](./action-patterns). Exact hook signature: [Action types](/api/Action/action-types#callbacks).
