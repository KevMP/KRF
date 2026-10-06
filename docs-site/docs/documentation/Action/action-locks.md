---
sidebar_position: 5
---

# Action Locks

`ActionController` owns exclusive named locks for active Action instances on one Actor. An Action claims its declared locks when it starts, and can claim more locks temporarily through its execution context.

| Surface | Ownership | Use |
| --- | --- | --- |
| `ActionDefinition.locks` | Loaded Action registry | Locks held for the complete active lifetime. |
| `ActionDefinition.interruptibleBy` | Loaded Action registry | Exact Action ids allowed to preempt this Action. |
| `canBeInterruptedBy(ctx, incoming)` | Running instance | Optional decision that can deny an allowlisted incoming Action. |
| `ctx:ClaimLocks(lockIds)` | Running instance | Temporary lock ownership returned as a releasable claim. |

Lock ids are opaque, non-empty game-defined strings such as `"Movement"`. They describe exclusive needs, not Action categories. Different Actions, or two instances of the same Action, can run together when their locks do not conflict. There are no priorities, implicit same-Action rules, or waiting queues.

## Lifetime locks and preemption

`locks` are acquired in the same commit that activates an instance. A request conflicting with another instance succeeds only when **every** conflicting owner permits preemption. The running owner's loaded `interruptibleBy` list must contain the incoming Action id exactly. If its captured `canBeInterruptedBy` callback exists, that callback must also return `true`. A callback cannot expand the static allowlist.

The following definitions let Dodge preempt Sprint for `Movement`:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)

local actions: { ActionTypes.ActionFactory } = {
	function(): ActionTypes.ActionDefinition
		return {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onInterrupt = function(_ctx: ActionTypes.ActionExecutionContext, reason: string)
				if reason == "ActionLockPreempted" then
					print("Sprint gave Movement to Dodge")
				end
			end,
		}
	end,
	function(): ActionTypes.ActionDefinition
		return {
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
		}
	end,
}

ActorRuntime.OnActorRegistered:Connect(function(actor)
	local controller: ActionTypes.ActionController = actor:GetController("ActionController") :: ActionTypes.ActionController
	local sprint: ActionTypes.ActionRequestResult = controller:RequestAction("Action.Sprint")
	if not sprint.accepted then
		warn(`Sprint rejected: {sprint.reason}`)
		return
	end
	local dodge: ActionTypes.ActionRequestResult = controller:RequestAction("Action.Dodge")
	if not dodge.accepted then
		warn(`Dodge rejected: {dodge.reason}`)
	end
end)

local started: boolean, failure: Server.StartupFailure? = Server.Init({ actions = actions })
if not started then
	assert(failure ~= nil)
	error(`KRF startup failed: {failure.system}: {failure.reason}`)
end
```

When an Actor is registered, the example requests `Action.Sprint` and then `Action.Dodge` through its controller. KRF Interrupts the Sprint instance with `ActionLockPreempted`, transfers `Movement`, and starts Dodge. A non-allowlisted request returns `{ accepted = false, reason = "ActionLockConflict" }` without consuming a sequence id.

For multiple conflicting owners, KRF evaluates distinct owners in ascending sequence-id order. One denial leaves all owners active. On approval, KRF commits every Interrupt, releases old locks, cleans Action-owned active Tags, acquires the new locks, and activates the incoming instance with its declarative Tags before any resulting event or hook. For owners A and B and incoming Action C, normal post-commit dispatch is:

```text
A OnActionInterrupted
B OnActionInterrupted
C OnActionStarted
resulting Tag events
Property notifications
A onInterrupt
B onInterrupt
C onStart, if C is still active
```

Reentrant mutations can issue older pending Property notifications before the remaining Tag events; see [Property changes](../Property/property-runtime#changes).

Owner events and hooks each follow ascending sequence-id order. Hooks may synchronously request or terminate Actions; a nested call completes its own lifecycle dispatch before returning. KRF issues C's Started event before running any owner hook, so a hook can terminate C without reversing C's Started and terminal events. Signal listeners may also reenter synchronously and need not finish before hooks run. If a listener terminates C before its normal Started turn, KRF issues C's pending Started before C's terminal signal. This does not defer the nested call.

`canBeInterruptedBy` receives the running instance's `ActionExecutionContext` and a frozen `ActionInterruptionContext` containing the incoming `actor`, `actionId`, and original request `parameters`. For a scoped claim, the incoming parameters are the claiming instance's original request parameters. The hook is synchronous and must return a boolean. An error, yield, or non-boolean return denies preemption and returns `ActionInterruptDecisionFailed`, `ActionInterruptDecisionYielded`, or `ActionInterruptDecisionInvalidResult` respectively. The running Action stays active. KRF uses the callback captured for that exact activation, so it can read the same private factory state as its other callbacks.

Decision hooks may call back into KRF. KRF rebuilds a conflict plan when those calls change the owners of the requested locks, and rechecks request availability before committing. Unrelated Action changes leave the plan valid. Manual `InterruptAction` and `ctx:Interrupt()` do not consult the lock allowlist.

## Temporary scoped claims

Call `ctx:ClaimLocks({ "Movement" })` while the Action is active. Its signature is `ClaimLocks: (self: ActionExecutionContext, lockIds: { string }) -> (LockClaim?, string?)`. It returns `LockClaim, nil` after acquiring every requested lock, or `nil, reason` without acquiring any. A failed claim does not terminate the caller. The Action chooses whether to continue, end, or retry later.

```lua
-- Inside an Action factory's onStart callback.
onStart = function(ctx: ActionTypes.ActionExecutionContext)
	local claim: ActionTypes.LockClaim?, reason: string? = ctx:ClaimLocks({ "Movement" })
	if claim == nil then
		warn(`Movement unavailable: {reason}`)
		return
	end

	-- Perform the Action's Movement work while it remains active.
	claim:Release()
end
```

The claiming Action's id and original parameters are used for owner-side preemption decisions. An approved claim Interrupts each conflicting owner as a whole; claims have no separate interruption policy. KRF commits all owner Interrupts and acquires the claim before issuing every owner's `OnActionInterrupted` event in sequence-id order, then dispatching cleanup Tag events, Property notifications, and running their `onInterrupt` hooks in the same order. A scoped claim issues no Started event because the claiming Action is already active.

| Claim failure reason | Cause |
| --- | --- |
| `ActionLockRequestInvalid` | The lock list is malformed, or an id is empty, duplicated, or not a string. |
| `ActionLockClaimDenied` | A conflicting owner does not permit preemption. |
| `ActionInterruptDecisionFailed` / `ActionInterruptDecisionYielded` / `ActionInterruptDecisionInvalidResult` | A conflicting owner's decision hook fails. |
| `ActionInstanceNotActive` | The claiming instance terminated before acquisition. |

`LockClaim:Release()` has signature `Release: (self: LockClaim) -> ()`. An instance may hold the same lock through a lifetime claim and one or more scoped claims. Releasing one claim removes only its own ownership reason. `Release()` can be called more than once; it is also safe after Action termination. End, Interrupt, and controller destruction release all outstanding claims during terminal commit, before cleanup hooks run. A successful `ClaimLocks` call has crossed its acquisition commit, although interruption callbacks may reenter KRF and terminate the claimant before the call returns.

## Related

- [Action Runtime](./action-lifecycle)
- [Action Registry](./action-registry)
- [Action Controller API](/api/Action/action-controller)
