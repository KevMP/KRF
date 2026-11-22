---
title: Client Action requests
sidebar_label: Client requests
---

# Client Action requests

The client asks to start an Action; the server's `ActionController` decides whether it can run. A shared request catalog describes what may cross that boundary. It does not grant the Action or bypass its costs, Tags, locks or conditions.

Use `ClientActionRuntime` to send Start, Stop and Interrupt. It keeps follow-ups attached to the original activation, including when release arrives before the Start result.

## Share the wire contract

Both `Server.Init` and `Client.Init` receive the same declarative `actionRequestSchemas` catalog. For a parameterless `Meditate` Action that accepts release intent:

```lua title="ActionRequestSchemas.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local schemas: KRF.ActionRequestSchemas = {
	Meditate = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
}
return schemas
```

An empty entry permits parameterless Start. `stop = {}` permits parameterless Stop; omitting `stop` provides no Stop path. When parameters are needed, declare a [Schema](../schemas/guide) in `start` or `stop.parameters`.

The server must also register and grant `Meditate`. Its `onStopRequested` decides how to respond to release, such as ending the Action. Stop itself is nonterminal.

The client must supply a matching [WhileDown policy](./routes) for this release-required entry, even if some callers send direct requests. Requiring release also requires `onDisconnect = "Interrupt"`; connection closure then interrupts any still-running activation admitted under that contract.

## Keep the original request ID

For a direct request, supply the entire payload yourself:

```lua
local Actions = KRF.ClientActionRuntime
local originalId, reason = Actions.RequestAction(actorView, "Meditate")
if originalId == nil then
	warn(reason)
	return
end

-- Retain originalId in the game-owned interaction that will release it.
-- Later:
local stopId, stopReason = Actions.RequestStop(originalId)
```

`actorView` must be a current client Actor identity. The returned ID means the request was admitted locally, not accepted by the server. Follow-ups refer to this original Start, even if the player changes the controlled Actor before the result arrives. They never retarget whichever Action happens to have the same name later.

Early release is supported: the client can admit Stop before Start's acknowledgement arrives. KRF correlates the follow-up to that original activation. The server delivers wire Stop at most once per original Start; further deliveries are rejected with `ActionStopAlreadyDelivered`.

## Separate admission, outcome and visible state

`OnActionRequest` reports local admission, server outcomes and automatic input transitions. Start acceptance supplies the server's Action `sequenceId`. Combine that sequence with the original Actor identity when correlating server Action state.

An `Unknown` outcome means the client cannot establish the result. It does not establish rejection, and replaying Start or Stop could duplicate gameplay. A late final outcome can still arrive during the retained correlation window. Use event ordinals to order facts if your own callbacks defer work.

[ActionsView](../actors/client-views) answers which Actions the client may currently see running. It is a different observation channel: a ServerOnly Action need not appear there, and an absent view cannot prove it ended. Request results are also not a prediction or effects system. The game chooses how to present pending, accepted and uncertain intent.

## Authority stays on the server

Ordinary client control targets the player's own character Actor. `Server.Init` can supply `actionControlAuthority` to authorize other Actors, such as a possessed companion. That callback must be synchronous and return exactly true to permit delegated control. KRF rechecks authority before committing Start.

Stop and Interrupt use the connection's receipt for the original accepted activation. They don't resolve the currently selected Actor or request permission to start another Action. That lets a release still reach its original charge after local selection changes.

Client routing and Actor selection do not establish this permission. The shared catalog controls payload shape and which follow-ups are available; the Action's server definition controls gameplay admission.

## Give up control deliberately

`RequestInterrupt` asks the server to interrupt the original activation, using the contract's closed set of input interruption reasons. Local admission still does not prove cancellation. A definitively accepted Interrupt retires follow-up authority; Unknown or Rejected does not prove termination.

`RetireRequest` is local cleanup when game code deliberately gives up follow-ups. It sends nothing and leaves the server Action's lifetime alone. A directly started Action can retain follow-up authority after an accepted Stop because Stop is nonterminal.

See the [client API](./client-api) for wire fields, request observations and failures, or [Action routes](./routes) to let input manage these lifetimes.
