---
title: Commands
sidebar_label: Guide
---

# Commands

Use a Command when a client asks the server to change something and needs to know whether it worked. Choosing a training mode, for example, needs a server decision before the client can treat that choice as accepted. The Command defines the payload, permission check and handler for that operation.

For starting, stopping or interrupting an Action, use [Action requests](../actions/requests). For state clients must recover after joining, use a [replication domain](../replication/guide). A Command result describes one operation; it is not durable Actor state.

## Put authorization beside the operation

This catalog asks a game-owned Training Controller to change mode. Its `TrySetMode` method checks the game's rules and commits the change; the Command adapts its decision into a network result:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local Schema = KRF.Schema
type TrainingController = KRF.Controller & {
	TrySetMode: (mode: string) -> (boolean, string?),
}

local commands: { KRF.CommandDefinition } = {
	{
		id = "Training.SetMode",
		target = "Actor",
		request = Schema.Struct({ mode = Schema.Enum({ "Solo", "Group" }) }),
		authorize = KRF.CommandAuthorization.OwnerActor,
		handle = function(ctx: KRF.CommandContext, request): KRF.CommandHandlerResult
			local actor = assert(ctx.actor)
			local training = actor:GetController("Training") :: TrainingController?
			if training == nil then
				return { accepted = false, reason = "TrainingUnavailable" }
			end
			local accepted, reason = training.TrySetMode(request.mode)
			if not accepted then
				return { accepted = false, reason = reason or "ModeUnavailable" }
			end
			return { accepted = true }
		end,
	},
}
return commands
```

Pass the catalog through `Server.Init({ commands = commands })`. `OwnerActor` requires the requesting Player's current Character to be exactly the Actor's registered Model. Awareness or a matching UserId is not ownership. For an NPC interaction or another permission model, supply a custom synchronous authorizer that checks the game's rules.

Use `target = "None"` for an operation without an Actor. `AnyReadyClient` explicitly permits any ready requester; use it only when that is the intended permission.

## Keep the server decision synchronous

Authorization must be side-effect free and must not yield. Return `true, nil` to permit the handler, or `false, reason` to deny it. A denial needs a nonempty reason of at most 64 bytes. A malformed decision, such as false without a reason, faults authorization instead of producing a clean rejection.

The handler must also complete without yielding. It returns `{ accepted = true, result = ... }` or `{ accepted = false, reason = ... }`. Accepted results cannot include a reason; rejected results cannot include a payload. KRF cancels a yielding callback and reports the operation as uncertain.

Reject before changing gameplay. Returning rejection after a mutation does not undo it. If a callback faults after it may have changed state, KRF cannot safely report a clean rejection; the request can become uncertain instead.

For work that continues over time, let the handler admit work owned by the appropriate server system and return its immediate decision. Keep the ongoing state in that system and expose it through replication where needed.

## Subscribe before sending

```lua
local Commands = KRF.CommandRuntime
local connection = Commands.OnCommandResult:Connect(function(outcome)
	if outcome.commandId == "Training.SetMode" then
		print(outcome.requestId, outcome.status, outcome.reason)
	end
end)

local requestId, reason = Commands.Send("Training.SetMode", actorView, { mode = "Solo" })
if requestId == nil then
	warn(reason)
end
```

The Actor argument is an exact current ActorView, even if its Model has streamed out. A None-target Command requires nil in that position. A successful Send returns a connection-local request ID, not server acceptance. Correlate runtime events by that ID and release subscriptions with their consumer. A transport failure can report uncertainty before Send returns, so install the listener before making the call.

Payloads and results follow [Schemas](../schemas/guide). Omitting a schema permits only nil, not an arbitrary table. Admitted payloads cannot be changed by mutating the caller's table later.

## Treat uncertainty as its own outcome

`OnCommandResult` reports Accepted or Rejected. `OnCommandUncertain` reports Unknown when transport, timeout or execution faults prevent a definitive result. A late definitive result can still arrive during the correlation grace window.

Local admission reserves client correlation, not space in the server's queue. Server rate or queue pressure can refuse a request without sending a result, leaving the client to report a timeout. There is no automatic retry.

Unknown does not mean cancelled, rejected or rolled back. Do not automatically resend an operation that could have taken effect. Read recoverable state or use a game-specific reconciliation operation when the product needs a stronger answer.

Commands execute serially per requester. During authorization or handling, `ctx:GetPriorOutcome(requestId)` can inspect bounded history for an earlier request on that same connection. Verify its Command ID, target and status before using its result. That context access closes when the invocation ends. Missing history does not establish rejection and is not persistent gameplay storage.

For synchronous effects, the requester's result callback begins before later Actor state and semantic callbacks caused by that handler, including changes to other Actors. Older queued state and baselines keep their place. Completion of a yielding listener is not a fence, and work scheduled for a later task falls outside that ordering guarantee.

See the [Commands API](./api) for definitions, authorization helpers, events and failures.
