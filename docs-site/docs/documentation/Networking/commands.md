---
sidebar_position: 4
---

# Commands

Commands send bounded requests to server-owned gameplay systems. Supply a command catalog through `Server.Init({ commands = ... })`, then use `CommandRuntime.Send` on a successfully initialized client. See [Initializing KRF](../initializing-krf) for startup integration.

## Define and authorize a command

A catalog module returns an array of definitions. Every definition needs a unique nonempty `id`, `target = "None" | "Actor"`, an `authorize` callback, and a `handle` callback. Optional `request` and `result` schemas use the ordinary [bounded schema vocabulary](./schemas); each conservative maximum must fit within 16,384 bytes. Omitted schemas accept only `nil`. An optional schema may itself describe an optional value.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local ActionTypes = require(KRF.server.Action.types)
local Schema = require(KRF.shared.Networking.Schema)
local Authorization = require(KRF.server.Networking.CommandAuthorization)

local commands: { Types.CommandDefinition } = {
	{
		id = "Game.Interact",
		target = "Actor",
		request = Schema.Struct({ interactionId = Schema.Enum({ "Door", "Chest" }) }),
		result = Schema.Struct({ sequenceId = Schema.U32 }),
		authorize = Authorization.OwnerActor,
		handle = function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
			local actor = context.actor
			assert(actor ~= nil, "Actor-targeted command")
			local actions: ActionTypes.ActionController? =
				actor:GetController("ActionController") :: ActionTypes.ActionController?
			if actions == nil then
				return { accepted = false, reason = "InteractionUnavailable" }
			end
			local outcome = actions:RequestAction("Interact." .. request.interactionId)
			if not outcome.accepted then
				return { accepted = false, reason = "InteractionDenied" }
			end
			return { accepted = true, result = { sequenceId = outcome.sequenceId } }
		end,
	},
}

return commands
```

The game supplies the `Interact.Door` and `Interact.Chest` Action definitions and grants through its ordinary Action catalog. This is a game-defined interaction command. KRF registers no built-in Action Start/Stop commands. ActionController still owns grants, eligibility, declarative costs, and activation identity; commands do not bypass those rules.

`authorize(context, request)` must be side-effect free and non-yielding. Return `true, nil` or `false, reason`, where `reason` is a nonempty string of at most 64 bytes. `AnyReadyClient` explicitly permits any ready requester. `OwnerActor` requires the exact Player-to-Actor association maintained by Networking from the Player's direct Character Model. Awareness, a matching UserId, and a Model nested below Character do not establish ownership. Non-Character NPCs require an appropriate custom policy. A custom authorizer receives the resolved Actor and must check whatever permission the operation requires, such as interaction range or team rules.

`handle(context, request)` must also complete without yielding. It returns `{ accepted = true, result = ... }` or `{ accepted = false, reason = ... }`. A rejected outcome has no result. Reasons are nonempty and at most 64 bytes. Keep detailed diagnostics on the server. Treat a deliberate rejection as a pre-effect decision; returning rejection after mutating gameplay does not undo that mutation.

Startup validates and owns immutable copies of definitions and schemas without calling either callback. Invalid catalogs fail the startup transaction. Command identities, target modes, codes, and schemas are shared bootstrap metadata; callbacks and live state remain server-side. Declaration order does not affect codes. The combined domain/event/command/Hint bootstrap must fit within 65,536 bytes.

## None targets and custom policies

A command that does not address an Actor uses `target = "None"`. This catalog entry acknowledges a ready client's request without any semantic payload:

```lua
{
	id = "Game.Ping",
	target = "None",
	authorize = Authorization.AnyReadyClient,
	handle = function(): Types.CommandHandlerResult
		return { accepted = true }
	end,
}
```

Send it with `Commands.Send("Game.Ping")`. Passing an ActorView or a request value fails locally because this definition has neither target nor request schema.

For a custom interaction policy, replace the first example's `authorize` field. This fragment combines Character ownership with a server-authored game permission attribute:

```lua
authorize = function(context: Types.CommandContext): (boolean, string?)
	local owns, reason = Authorization.OwnerActor(context, nil)
	if not owns then return false, reason end
	if context.player:GetAttribute("InteractionsDisabled") == true then
		return false, "InteractionsDisabled"
	end
	return true, nil
end,
```

The permission check reads server state and makes no mutation. An NPC interaction policy would instead check that game's permission and range rules; it should not use OwnerActor for an unassociated NPC.

## Send and observe outcomes

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Commands = require(KRF.client.Networking.CommandRuntime)
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local Types = require(KRF.client.Networking.types)

Commands.OnCommandResult:Connect(function(outcome: Types.CommandResult)
	if outcome.status == "Accepted" then
		print(outcome.requestId, outcome.result)
	else
		warn(outcome.requestId, outcome.reason)
	end
end)

Commands.OnCommandUncertain:Connect(function(outcome: Types.CommandResult)
	warn("Execution is uncertain", outcome.requestId, outcome.reason)
end)

-- actorId is an Actor identity supplied by this game's selection system.
local function interact(actorId: string): ()
	local view = Registry.GetActorViewById(actorId)
	if view == nil then return end
	local requestId, reason = Commands.Send("Game.Interact", view, { interactionId = "Door" })
	if requestId == nil then warn(reason) end
end

return interact
```

`Send` returns a raw request id on local admission. This does not mean that the server accepted or even executed the request. Local rejection returns `nil, reason` and sends nothing. Subscribe to runtime events before sending; there are no per-request objects.

For Actor commands, pass the exact current registry-owned, available ActorView. Copies, forged tables, removed views, and views from an earlier client session fail locally. An absent local Model is allowed. Recoverable desync retains the last valid available view; terminal failure invalidates it. `target = "None"` requires no ActorView. On the wire, targeting uses a connection-local private handle; neither the facade nor event payloads expose handles, buffers, or transport instances. The server revalidates the handle against its current Actor lifetime before authorization.

`OnCommandResult` delivers Accepted or Rejected. `OnCommandUncertain` delivers Unknown. Both carry an immutable record with `requestId`, `commandId`, optional `targetActorView`, `status`, and the applicable `result` or `reason`. Schema-owned result tables are immutable. Events use KRF's standard read-only Event API: `Connect`, `Once`, and `Wait`.

## Correlate follow-up requests

Request ids increase within one connection and are never reused or wrapped. Commands execute serially for each requester. Other connections continue independently.

Within a handler, `context:GetPriorOutcome(requestId)` looks up an earlier completed request on that connection. Records contain `requestId`, `commandId`, optional `targetActor`, `status`, and validated result/reason. They retain no original request payload. Check the command id, target, and Accepted status before using a prior result identity. A game-defined follow-up can use an accepted `sequenceId` to address an activation through ActionController. Current, future, other-connection, and evicted requests return `nil`; unavailable history does not imply rejection.

For example, a game can register this diagnostic follow-up definition alongside `Game.Interact`. It returns an earlier accepted interaction's sequence identity without waiting for its first result to reach the client:

```lua
{
	id = "Game.QueryPrior",
	target = "Actor",
	request = Schema.Struct({ earlierRequestId = Schema.U32 }),
	result = Schema.Struct({ sequenceId = Schema.U32 }),
	authorize = Authorization.OwnerActor,
	handle = function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
		local prior = context:GetPriorOutcome(request.earlierRequestId)
		if prior == nil or prior.status ~= "Accepted"
			or prior.commandId ~= "Game.Interact" or prior.targetActor ~= context.actor then
			return { accepted = false, reason = "PriorUnavailable" }
		end
		return { accepted = true, result = { sequenceId = prior.result.sequenceId } }
	end,
}
```

With a current selected `view`, the client can send both immediately:

```lua
local first, reason = Commands.Send("Game.Interact", view, { interactionId = "Door" })
if first ~= nil then
	local followUp, followUpReason = Commands.Send("Game.QueryPrior", view, { earlierRequestId = first })
	if followUp == nil then warn(followUpReason) end
else
	warn(reason)
end
```

The returned identity is the same sequence used by ActionsView. It does not promise that the activation is still running. A follow-up that operates on the activation must also validate its current state through ActionController.

The history also retains known indeterminate executions as Unknown, without an accepted sequence identity. It has hard count, byte, and lifetime bounds; it is not durable gameplay state. Store long-lived ownership in the appropriate gameplay system.

## Ordering and uncertainty

For the requester, the result callback begins before Actor state and semantic callbacks caused synchronously by that handler, including effects on other Actors. Older ready publications and baselines keep their place before the result. Other observers continue through their normal streams. Work scheduled for a later task, timer, or Heartbeat is outside that handler's causal scope. A yielding client event listener cannot hold up gameplay indefinitely; its callback begins first, but its eventual completion is not a fence.

A thrown or yielding callback, malformed handler return, invalid result, or publication failure escaping the handler produces Unknown rather than a false definitive rejection. Committed effects are not rolled back. Inspect authoritative gameplay state before retrying; blindly resending may repeat an operation.

The client reports `CommandTimeout` after 10 seconds without an outcome. Timeout neither cancels server execution nor means rejection. Any uncertainty starts a 10-second grace window for one late Accepted/Rejected on the same connection; duplicate definitive results are ignored. Closing the runtime reports remaining pending operations as Unknown and releases timers and metadata. A terminal receive-queue overflow ends the client connection, clears Actor consumers, and stops command admission. It does not restart initialization.

Finite global and per-connection count/byte limits cover ingress and queued/in-progress commands; connection-local limits also bound pending correlations, history, outbound results and temporarily held publications. Author handlers run through a bounded fair dispatcher, not directly as an unbounded receive-callback drain. Same-requester FIFO and prior-outcome installation before the next handler remain intact.

Admission protects opportunities in both aggregate attempt and pending-work budgets, with a shared borrowing pool. Ready membership and rotating protected bands accommodate late arrivals and rosters larger than protected capacity. Already admitted work is never evicted to make room for a newcomer. This prevents a few noisy clients consuming every opportunity indefinitely; it does not promise immediate admission, equal throughput, a fixed wait time or utilization of every reserved slot. Local limits, output capacity and handler cost still matter.

Output slots and maximum result bytes are reserved before author callbacks run. A result remains queued in its causal position, ahead of that request's synchronous publications but behind older ordered work. Closing a connection or faulting releases ownership exactly once, including after staged work unwinds. Capacity exhaustion can refuse execution without a reply; a locally admitted client then relies on its uncertainty timeout. KRF never turns a possibly mutated execution into a fabricated definitive rejection. Limits are internal policies, not gameplay quotas or a delivery guarantee under overload.

## Related

- [CommandRuntime API](/api/Networking/command-runtime)
- [CommandAuthorization API](/api/Networking/command-authorization)
- [ActorViews](./actor-views)
- [Maintainer budgets and result fences](./maintaining-networking)
- [ActionController](/api/Action/action-controller)
