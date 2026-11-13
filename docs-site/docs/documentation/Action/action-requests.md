---
sidebar_position: 12
---

# Action Requests

Action requests let a client ask the server to Start, Stop or Interrupt an Action on an Actor it controls. A shared request schema module declares which Actions accept client requests and the typed parameters each one carries. `ActionController` still decides every Start through grants, requirements, costs, locks and `onCanStart`; the request contract is not a grant.

Use [Action input policies](./action-input) for routed input or [`ClientActionRuntime`](/api/Action/client-action-runtime) for explicit requests. Both use the same schema checks and server authority.

## Declare requestable Actions

Put one ModuleScript where both server and client can require it, such as `ReplicatedStorage`. It returns a table keyed by concrete Action id. Only Actions listed here can be requested by a client; `ClientVisible` or `autoGrant` alone never makes an Action requestable, and a listed `ServerOnly` Action stays subject to ordinary Action security.

```lua title="ActionRequestSchemas.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)

local aim = Schema.Struct({ x = Schema.F32, y = Schema.F32, z = Schema.F32 })

return {
	-- A typed Start with no follow-ups.
	["Combat.Fireball"] = { start = Schema.Struct({ aim = aim }) },
	-- A held Action: released with a parameterless Stop, interrupted if the client disconnects.
	["Movement.Sprint"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	-- Typed Start and Stop parameters.
	["Technique.Cast"] = {
		start = Schema.Struct({ techniqueId = Schema.String(64), aim = aim }),
		stop = { parameters = Schema.Struct({ releaseAim = aim }) },
		allowInputInterrupt = true,
		onDisconnect = "Interrupt",
	},
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `start` | none | [Schema](../Networking/schemas) for Start parameters. Omitted means the Start carries no parameters. |
| `stop` | none | Enables Stop. `{}` is a parameterless Stop; `{ parameters = schema }` types its parameters. |
| `allowInputInterrupt` | `false` | Lets the client Interrupt its own activation with a fixed input reason. |
| `requiresClientRelease` | `false` | Requires genuine release-driven Stop and an explicit client WhileDown policy. Requires `stop` and `onDisconnect = "Interrupt"`; Stop remains nonterminal. |
| `onDisconnect` | `"Keep"` | `"Interrupt"` interrupts the activation when its requesting connection closes; `"Keep"` leaves it running. |

Each Action id is a valid UTF-8 string of at most 96 bytes. Each parameter schema's encoded maximum must fit within 8,192 bytes. Unknown fields fail startup.

| Startup failure reason | Cause |
| --- | --- |
| `ActionRequestSchemasMustBeTable` / `ActionRequestSchemaMustBeTable` | The module or an entry is not a table |
| `ActionRequestIdInvalid` / `ActionRequestIdTooLong` | An id is empty, not valid UTF-8, or longer than 96 bytes |
| `ActionRequestFieldUnknown` / `ActionRequestFlagInvalid` | An entry has an unknown field, or a flag is not a boolean |
| `ActionRequestStartSchemaInvalid` / `ActionRequestStopInvalid` / `ActionRequestStopSchemaInvalid` | A Start schema, Stop table or Stop parameter schema is invalid |
| `ActionRequestPayloadTooLarge` | A parameter schema can encode more than 8,192 bytes |
| `ActionRequestDisconnectPolicyInvalid` | `onDisconnect` is neither `"Keep"` nor `"Interrupt"` |
| `ActionRequestReleaseRequiresStop` / `ActionRequestReleaseRequiresDisconnectInterrupt` | `requiresClientRelease` lacks `stop` or `onDisconnect = "Interrupt"` |

## Initialize both sides

Pass the same module to [`Server.Init`](/api/Server/) and [`Client.Init`](/api/Client/). Supply client-only `actionInputPolicies` alongside it. The Sprint declaration above requires an explicit `{ activation = "WhileDown" }` entry; a missing policy defaults to OneShot only when the wire contract permits it. See [Initializing KRF](../initializing-krf) for startup integration.

The server compiles the module before any game callback runs and checks every listed id against the Action catalog (`ActionRequestUnknownAction`). Failures use `system = "ActionRequest"`. The client compiles its copy before it contacts the server, and fails startup if the server did not publish compatible request commands. A client without `actionRequestSchemas` starts normally and sends no Action requests.

Each Action's compiled contract is reduced to a 32-bit tag. A Start whose tag differs from the server's is rejected with `ActionContractMismatch`, so a client built from a stale module cannot send parameters the server would read differently.

## Who may request

By default a player may request Actions only on the Actor of their own Character, using the same association as [`OwnerActor`](../Networking/commands#define-and-authorize-a-command). For delegated control such as mounts or possession, pass a server-only policy:

```lua
Server.Init({
	actions = actions,
	actionRequestSchemas = schemas,
	actionControlAuthority = function(player: Player, actor): boolean
		-- RiderUserId is a server-authored attribute on the mount's Model.
		local model = actor.model
		return model ~= nil and model:GetAttribute("RiderUserId") == player.UserId
	end,
})
```

The policy is consulted only when the player does not own the Actor, must not yield, and must return exactly `true` to allow control. An error or any other value denies it. Control is checked again immediately before the Action commits: after `onCanStart` and any `canBeInterruptedBy` decision, before costs are paid or locks are preempted. Control lost during those callbacks still rejects the Start with `ActorNotOwned`.

## Start, Stop and Interrupt

| Request | Server behavior |
| --- | --- |
| Start | Decodes the parameters, reserves a receipt, then calls `ActionController` with them as the activation's `parameters`. An accepted Start returns its `sequenceId`. |
| Stop | Delivers decoded parameters to `onStopRequested` as `request.parameters`. Nonterminal; the Action decides whether to End. |
| Interrupt | Interrupts the activation with the client's reason, such as `"FocusLost"` or `"ActorSwitched"`. Requires `allowInputInterrupt`. |

Stop and Interrupt always address the activation created by their original Start, not whatever the client controls now. A later slot or Actor switch never retargets them. A Stop reaches `onStopRequested` at most once per activation; a duplicate is rejected with `ActionStopAlreadyDelivered`. A follow-up for an activation that has already ended is rejected with `ActionReceiptUnknown`.

KRF validates Stop parameters against their schema only. It does not judge whether a structurally valid value makes sense for the game. Handle that in the Action:

```lua
onStopRequested = function(ctx, request)
	local releaseAim = request.parameters.releaseAim
	if releaseAim.y < -1 or releaseAim.y > 1 then
		-- Out-of-range aim: fall back to the aim captured at Start.
		releaseAim = ctx.parameters.aim
	end
	castAt(releaseAim)
	ctx:End()
end,
```

Rejections carry the `ActionController` reason, such as `ActionNotGranted`, when it fits the 64-byte command reason limit; a longer or malformed reason becomes `ActionRequestRejected`. As with other [commands](../Networking/commands#ordering-and-uncertainty), Unknown means the request may have executed. Clients never retry a Stop or Interrupt that became Unknown.

## Observe local requests {#observe-local-requests}

Subscribe to `ClientActionRuntime.OnActionRequest` for the same facts from routed input and explicit calls. KRF supplies the original Actor, concrete Action, request identity and input provenance; game code does not need to reconstruct them from the current loadout.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local Actions: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)

local connection = Actions.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent)
	if fact.kind == "RequestAdmitted" then
		print("Locally admitted", fact.actionId, fact.operation, fact.requestKey)
	elseif fact.kind == "InputTransition" then
		print("Local input decision", fact.actionId, fact.transition, fact.originalStartKey)
	else
		print("Request outcome", fact.actionId, fact.operation, fact.status, fact.reason)
		if fact.status == "Accepted" and fact.operation == "Start" then
			local instance = fact.actor:GetActions():GetAction(fact.sequenceId)
			print("Original authoritative instance, if currently visible", instance)
		end
	end
end)

-- Disconnect when the UI or other game-owned consumer is torn down.
-- connection:Disconnect()
```

The [API reference](/api/Action/client-action-runtime#on-action-request) lists each variant's fields. Payloads are frozen and contain no parameter/aim tables, policy callbacks or native input objects.

| Fact | Consequence |
| --- | --- |
| `RequestAdmitted` | Validation and local command admission succeeded. This does not establish server success or active state. |
| `RequestOutcome`, `Accepted` Start | The server accepted the original Start. Its server-issued `sequenceId` belongs to the original `actor`. |
| `RequestOutcome`, `Accepted` Stop | The server handled nonterminal Stop. The Action may still run. |
| `RequestOutcome`, `Rejected` | Definitive denial for this command. No route fallback or automatic replay follows. |
| `RequestOutcome`, `Unknown` | The command may have executed. It is neither rejection nor cancellation. |
| `InputTransition` | An original local input ownership decision. Any admitted Stop/Interrupt and its outcome are separate facts. |

Admission is created from validated local command metadata. A request rejected by selection, its parameter producer, encoding or local capacity produces no admission/preview fact. A physically failed send can still be locally admitted and then become Unknown.

### Input decisions retain their original target

| `transition` | Meaning |
| --- | --- |
| `GenuineRelease` | Release of the exact owned WhileDown Bool press selected Stop. Reported even if Stop preparation or admission subsequently fails. |
| `ToggleOff` | A matching second occurrence selected the original Toggle's Stop; this is not physical release. |
| `InvalidatedInterrupt` | Original ownership was invalidated and its captured policy selected best-effort Interrupt. Interrupt may still fail admission. |
| `InvalidatedKeep` | Automatic ownership was detached with no automatic Stop/Interrupt. The server Action may continue. |

Disabling a native context generates cancellation, never genuine release. Actor/configuration invalidation is observed after coherent local commit. Merely changing a game-owned dynamic resolver's future target leaves a continuous route/press intact: a held Rasengan still releases Rasengan, even if the next press would choose Fireball. Direct requests never fabricate input transitions or sample input producers.

### Keys, clocks and scheduled listeners

`requestId` identifies a command within its connection. `requestKey` is an opaque stable string derived from a non-reused local incarnation and that id. `originalStartKey` equals the initial Start's key. A Stop/Interrupt carries its own key plus that original key, even when called manually for an input-started Action. Numeric ids and ordinals can restart after reconnect; keys distinguish the incarnations. Keys do not grant server authority.

`inputOccurredAt` comes from the selected original input candidate and appears only on input-driven Start admissions, including deferred recognition. `observedAt` records fact creation on the client's monotonic observation clock. Neither timestamp is callback execution time or a synchronized server clock. Only compare them when the owning input and observation clocks share a clock domain.

The public Event uses yield-safe scheduled listeners. An admission callback can resume after an outcome callback. For a current status projection, compare `eventOrdinal` for the same `originalStartKey` before applying a fact; an older ordinal must not regress newer state. A historical consumer needing every distinct fact must instead use bounded reordering. Blindly dropping older facts can lose a separate GenuineRelease or invalidation decision. There is no ordering guarantee across public request, command and ActionsView callbacks.

Trusted framework consumers can use an optional synchronous ordered handoff after local egress staging/attempt, outside the transport-critical section, without an added frame or round trip. Correlation itself is reserved before egress. The handoff is for bounded, non-yielding framework work; errors, yields, reentry and excessive work quarantine that subscriber without replaying commands. Downstream rendering or asset setup belongs outside this path. Games use the public Event; no Presentation Runtime or visual asset is required to initialize or request Actions.

### Authoritative state and correlation lifetime

Use `fact.actor:GetActions()` with Accepted Start's `sequenceId`, rather than the currently controlled Actor or Action id alone. Two Actors can have equal sequence ids, and one Actor can run several instances of the same Action. A Start can synchronously End or Interrupt before its result is observed. Accepted never manufactures a local active instance.

ClientVisible state and lifecycle remain in ActionsView; ServerOnly Actions have no visible entry. A missing entry does not prove denial, termination or a required cosmetic correction. NPC and other-player presentation can consume ActionsView and replicated Tags without any local request event. Requester-specific result-before-publication applies only to synchronous command-caused authoritative publication; unrelated authoritative events and scheduled public listeners have no such order guarantee.

OneShot/direct results remain correlated by the existing pending command lifetime after automatic input tracking ends. Unknown can be followed by a supported late Accepted/Rejected for the same key during the existing command grace interval. After that interval KRF does not invent a definitive result or retain presentation history. An admitted Stop that becomes Unknown is not replayed.

ActorView unavailability retires input ownership but does not erase legitimate pending request correlation. A later result still names that exact unavailable ActorView and does not revive it. Connection closing passes through the command runtime's unresolved Unknown facts, then disposes private subscriptions. Already-running/scheduled public callbacks may still complete with old immutable keys after teardown; consumers must not apply them to a new incarnation.

## Receipts and disconnects

The server tracks each accepted Start as a receipt for its exact connection. A reconnect never inherits an earlier connection's receipts. Receipts are bounded to 64 per connection and 16,384 per server; a Start beyond either bound is rejected before any Action effect.

When a connection closes, its receipts are removed, then each live activation declared `onDisconnect = "Interrupt"` is interrupted with `ActionRequestDisconnected`. `"Keep"` activations keep running under server control.

KRF has no heartbeat and no maximum hold duration. A held Action such as Sprint runs until its Stop arrives, the Action ends itself, or its connection closes. If a connection stays open but a release never arrives, the server cannot know the key was released. Where that matters, the Action should end itself, for example with a game-specific maximum duration in `onUpdate`.

Stop and Interrupt keep a small protected share of command capacity, so a burst of ordinary commands cannot use every slot a client needs to stop a running Action. That share sits inside the same overall limits; it does not guarantee delivery over a failing connection.

## Related

- [Action lifecycle](./action-lifecycle)
- [Action input](./action-input)
- [Commands](../Networking/commands)
- [Schemas](../Networking/schemas)
- [Initializing KRF](../initializing-krf)
- [ActionController API](/api/Action/action-controller)
