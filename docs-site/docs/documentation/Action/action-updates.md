---
sidebar_position: 4
---

# Action Updates

An Action can opt into recurring server updates by defining `onUpdate(context, deltaTime)`. `ActionController` steps only active instances whose per-request factory result contains this hook. Each instance uses the callback and private state captured for its own activation; the startup factory callback is never used for updates.

## Timing and callback contract

```lua
onUpdate = function(context: ActionTypes.ActionExecutionContext, deltaTime: number): ()
```

KRF uses one scheduler for all update-enabled Actions. It checks `RunService.Heartbeat` but dispatches at most one update pass per 0.05 seconds (20 Hz).

`deltaTime` is the elapsed time in seconds since this instance was activated, or since its previous `onUpdate` began. It is finite and positive, but it can be larger than `0.05`. Use it to advance time-based game state. Do not treat `onUpdate` as a render, physics, or movement-frame callback.

`onUpdate` must finish synchronously. It may call `context:End()` or `context:Interrupt(reason)`, but it must not yield through `task.wait()`, `Event:Wait()`, or another suspending operation. If it errors or attempts to yield, KRF contains the failure, cancels any yielded invocation, and Interrupts the still-active instance once with `ActionUpdateFailed`. Other Actions continue updating. A callback that already Ended or Interrupted its own instance does not cause a second terminal transition.

## A stepped Action

This factory keeps a separate elapsed counter for each accepted `Action.Channel` request. Register it with `Server.Init({ actions = { createChannel } })`, then request the Action through the Actor's `ActionController` as shown in [Action Runtime](./action-lifecycle).

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
		onUpdate = function(context: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			elapsedSeconds += deltaTime
			if elapsedSeconds >= 2 then
				context:End()
			end
		end,
		onEnd = function(context: ActionTypes.ActionExecutionContext): ()
			print(`Channel completed for {context.actor:GetId()}`)
		end,
	}
end
```

An Action without `onUpdate` remains active without recurring Action callback work. It can instead react to stop requests or game-owned events.

## Changes during a pass

KRF captures all update-eligible instances before the first callback in each pass. Within one Actor, captured callbacks run in ascending sequence-id order; no order is promised between Actors. Immediately before each callback, KRF checks that the same instance is still active and update-enabled.

An Action started during a pass waits until a later pass, including when a callback starts it on another Actor. An Action that Ends, Interrupts, or is destroyed before its turn is skipped. When the last update-enabled Action terminates, the scheduler disconnects and clears its accumulated time; a later Action starts with a fresh interval.

## Related

- [Action Runtime](./action-lifecycle)
- [Action Registry](./action-registry)
- [Action Controller API](/api/Action/action-controller)
