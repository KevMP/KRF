---
sidebar_position: 3
---

# Run Actions

`ActionController` starts and owns active Actions for one Actor. Server gameplay code starts an Action through `RequestAction`; Action definitions supply optional callbacks for decisions and lifecycle behavior.

| Concept | What it means |
| --- | --- |
| Registered Action | Its definition exists in `ActionRegistry`. |
| Granted Action | This Actor is allowed to request it. A grant does not start it. |
| Accepted request | The controller created an Action instance and returned its sequence id. |
| Active Action | That instance has not Ended or been Interrupted. |

An accepted Action may already have terminated by the time `RequestAction` returns, for example when its `onStart` calls `ctx:End()`. Sequence ids increase within one Actor's controller and are never reused during that controller's lifetime. Several instances of the same Action can be active at once.

## Request an Action

Obtain the Actor's controller after registration, then request an Action that the Actor has been granted:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)

ActorRuntime.OnActorRegistered:Connect(function(actor)
	local actions: ActionTypes.ActionController = actor:GetController("ActionController") :: ActionTypes.ActionController
	local result: ActionTypes.ActionRequestResult = actions:RequestAction("Action.Dodge")
	if not result.accepted then
		warn(`Dodge rejected: {result.reason}`)
		return
	end

	print(`Dodge accepted as #{result.sequenceId}`)
end)
```

The Action must exist, be granted, and pass its optional `onCanStart` decision. KRF calls its factory for this request, then uses that result's callbacks throughout the activation. The factory and `onCanStart` must finish synchronously without yielding. `onCanStart` receives a frozen `ActionStartContext` with `actor`, `actionId`, and the original `parameters`. It may return `false, "GameReason"` to reject with a game-defined reason. KRF rechecks the Actor and grant after the callback, so a grant revocation or Actor teardown during the decision prevents acceptance. A rejection creates no instance and consumes no sequence id.

Request parameters are opaque server-side game data. KRF passes the same value to `onCanStart` and the accepted Action; it does not copy or serialize it. Validate client-originated data before calling this server API.

## Use the execution context

An accepted instance receives a frozen `ActionExecutionContext`. Its `actor`, `actionId`, `sequenceId`, and `parameters` identify the request. `ctx:IsActive()` checks that exact instance, including when several instances share one Action id. Declare private state inside the factory; callbacks from one activation share those local variables.

```lua
local function createCharge(): ActionTypes.ActionDefinition
	local startedAt = 0
	return {
		id = "Action.Charge",
		visibility = "ServerOnly",
		autoGrant = true,
		onStart = function(_ctx: ActionTypes.ActionExecutionContext)
			startedAt = os.clock()
		end,
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext, request: ActionTypes.ActionStopRequest)
			releaseCharge(os.clock() - startedAt, request.parameters)
			ctx:End()
		end,
		onInterrupt = function(_ctx: ActionTypes.ActionExecutionContext, reason: string)
			cancelCharge(startedAt, reason)
		end,
	}
end

-- Pass createCharge in Server.Init({ actions = { createCharge } }).
```

Here `releaseCharge` and `cancelCharge` represent your game functions. Each Charge request gets a fresh `startedAt` variable. Game code can retain the context to query or terminate that instance.

## Stop, End, and Interrupt

`RequestStop(sequenceId, parameters?)` invokes that instance's `onStopRequested(ctx, request)` synchronously. `request.parameters` is the original stop parameter value. The callback must not yield. Stop does not End or Interrupt the Action automatically, and repeated stop requests are allowed while it remains active. The callback can call `ctx:End()` when its work is complete.

For a held Action, start the effect in `onStart` and finish it in `onStopRequested`:

```lua
onStart = function(_ctx: ActionTypes.ActionExecutionContext)
	startSprinting()
end,
onStopRequested = function(ctx: ActionTypes.ActionExecutionContext, _request: ActionTypes.ActionStopRequest)
	stopSprinting()
	ctx:End()
end
```

KRF starts `onStart` before `RequestAction` returns. Returning from `onStart` leaves the Action active; a long-lived Action may set up game behavior and return, then be terminated later by sequence id.

An instant Action can finish itself; an Action whose start callback only sets up game behavior stays active until another call terminates it:

```lua
local function createDodge(): ActionTypes.ActionDefinition
	return {
		id = "Action.Dodge",
		visibility = "ServerOnly",
		onStart = function(ctx: ActionTypes.ActionExecutionContext)
			-- Apply the game effect.
			ctx:End()
		end,
	}
end
```

Use `ctx:End()` or `EndAction(sequenceId)` for normal completion. Use `ctx:Interrupt(reason)` or `InterruptAction(sequenceId, reason)` for interruption. A successful transition makes `ctx:IsActive()` false before `onEnd` or `onInterrupt` runs. These cleanup callbacks must finish synchronously without yielding. Their errors do not undo the transition. A failing `onStart` automatically Interrupts an instance that is still active.

`ctx:End()` and `ctx:Interrupt()` are ordinary calls: Action code should `return` afterward if it has no more synchronous work to do. KRF retires a suspended `onStart` invocation when its instance terminates. Tasks or connections created separately by game code remain game-owned.

## Observe transitions and teardown

`OnActionStarted`, `OnActionEnded`, and `OnActionInterrupted` report committed transitions. Their payloads contain the Actor, Action id, and sequence id; interruption also includes the reason. KRF issues Started before beginning `onStart`, and issues a terminal event before its cleanup hook. Event subscribers run through the normal non-blocking Signal behavior, so their completion is not part of the Action request or termination result.

Destroying the controller Interrupts every active Action with `ActionControllerDestroyed`, runs each `onInterrupt` best-effort, and retires suspended starts. Later public Action mutations fail. Removing a grant by itself does not terminate an Action already running under that grant.

## Related

- [ActionController API](/api/Action/action-controller)
- [Action grants](./action-grants)
- [Action catalog](./action-registry)
