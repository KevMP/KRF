---
title: Actions
---

# Actions

An ability often needs several decisions to agree: the character knows it, can afford it, isn't stunned, and can interrupt whatever is already running. An Action gives those decisions one server-owned lifecycle. Your callbacks supply the ability's behavior and decide when it ends.

## Give each activation its own state

An Action catalog contains factory functions. KRF calls a factory during startup validation and again for an execution; keep it synchronous and free of gameplay side effects. Put counters and phase state inside the factory, where they belong to one activation.

For example, Guard can hold a stance lock and a Blocking Tag until the player asks to stop. This definition assumes Blocking is already registered:

```lua
local function Guard(): KRF.ActionDefinition
	return {
		id = "Guard",
		visibility = "ClientVisible",
		autoGrant = true,
		locks = { "Stance" },
		activeTags = { "Blocking" },
		onStopRequested = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end
```

Include the factory in `Server.Init({ actions = ... })`. Static declarations are installed at startup. Callback-local state belongs to the execution; changing a factory's later static fields isn't a live definition update.

## Grant access before requesting

`autoGrant = true` gives every Actor access. For earned abilities, keep it false and replace the grant set belonging to a game-owned source:

```lua
local actions = actor:GetController("ActionController") :: KRF.ActionController
local granted: boolean, reason: string? = actions:SetGrants("Sect", { "Kindle" })
assert(granted, reason)
```

Effective access is the union of automatic grants and all named source sets. Clearing the Sect set doesn't remove a grant from equipment or remove an automatic grant. Losing a grant prevents future starts; it doesn't cancel an existing activation.

Server code can call `RequestAction`. Client input uses [Action requests](./requests), which reach the same server admission rules.

## Admit the whole start

KRF checks that the Actor is enabled and the Action is registered and granted, then checks its Tag and Resource requirements. It creates execution callbacks and consults `onCanStart` for additional game rules. Lock decisions can reject or permit interruption of existing owners. Final validation and payment happen before the activation becomes observable.

Declare upfront payment with `costs`, not a `Spend` call in `onCanStart`. A rejected start installs no incoming activation, spends no declared costs and consumes no sequence ID. Explicit mutations your decision callbacks perform are still real game mutations; KRF doesn't undo them when a later check rejects the request.

```lua
resourceRequirements = { Mana = { minPercent = 0.5 } },
costs = { Mana = { amount = 20, multiplierProperty = "ManaCostMultiplier" } },
```

All supplied thresholds are inclusive and use pre-spend state. A cost is paid once on acceptance. It can be fixed, based on Resource capacity or scaled by an assigned resolved Property. The [API](./api#resource-requirements-and-costs) specifies the formulas.

After acceptance, losing a required Tag or falling below a Resource threshold doesn't automatically stop the ability. Continuous enforcement belongs in game callbacks or an event consumer.

## Own a status or leave an effect behind

`activeTags` applies Tags for the activation. End, Interrupt and destruction remove applications that activation created and still owns. Ignoring a duplicate or refreshing an existing application does not transfer ownership to the Action; a later external refresh can also leave an application outside its cleanup. [Tag ownership](../tags/guide#let-an-action-own-a-status) explains those interactions.

`appliedTags` applies an ordinary Tag that follows its own duration and duplicate rules after the Action ends.

Activation commits its costs, lock ownership, Tag effects and derived state before public notifications. A listener reading Resources or Properties during Started sees the committed result. Reentrant callbacks can cause newer changes before later notifications finish; query current state when it matters.

## End, interrupt or handle a stop request

Returning from `onStart` leaves the Action active. Call `context:End()` to complete it or `context:Interrupt(reason)` to cancel it. A Stop request only invokes `onStopRequested`; that callback decides whether and how to terminate.

An accepted request stays accepted even if `onStart` immediately ends it. Its positive `sequenceId` identifies that activation on that Actor, not the Action definition or a network request.

Termination makes the activation inactive and releases locks, updates and remaining owned active Tags before terminal callbacks. End and Interrupt are alternatives; an activation has only one terminal transition. Neither refunds declared costs.

An Action can keep `onStart` suspended for its active lifetime; KRF cancels that suspended coroutine when the activation ends. Separately spawned tasks and connections remain your responsibility. Share cleanup between `onEnd` and `onInterrupt` when both need to release those resources, and recheck `context:IsActive()` after calls that can reenter gameplay.

## Update over time

Use `onUpdate(context, deltaTime)` for recurring synchronous work. KRF dispatches at most 20 times per second and supplies elapsed time for that specific activation. The first delta covers time since activation; later deltas cover time since its previous update. Delayed frames produce a larger delta, not catch-up callback bursts.

An errored or yielding update interrupts the still-active Action with `ActionUpdateFailed`. Factories, start decisions, interruption decisions and cleanup hooks must also complete without yielding. [Actions API](./api#callbacks) lists the different failure contracts.

## Exclude conflicting abilities

Lock names are game-defined strings. Actions holding the same lock cannot run together. The current owner can allow an incoming Action by listing its ID in `interruptibleBy`; optional `canBeInterruptedBy` can narrow that permission.

An Action ID alone doesn't exclude another activation of that Action. Without a conflicting lock, the same Actor can run several instances, each with its own callback state and sequence ID. Declare a shared lock when the ability should have only one active instance.

For Dodge to interrupt Guard, both declare the same lock and Guard lists Dodge. Every conflicting owner must allow the incoming Action. Acceptance interrupts those owners with `ActionLockPreempted` and installs the new owner before notifications. Explicit game-directed Interrupt bypasses that lock policy.

Use `context:ClaimLocks(ids)` for a releasable claim during one phase. Releasing a scoped claim doesn't remove a lifetime lock or another claim. There is no lock wait queue or general Action priority system.

## Observe on the appropriate side

Server lifecycle events include Actor and sequence identity. Clients read only active `ClientVisible` activations through [ActionsView](../actors/client-views-api#actionsview). That view does not expose grants, parameters, internal phases or interruption reasons. Local request outcomes come from ClientActionRuntime, separately from replicated active state.

See [Actions API](./api), [Action requests](./requests) and [Break through](/tutorial/break-through).
