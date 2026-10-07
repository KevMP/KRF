---
sidebar_position: 1
---

# Actions Overview

An Action is a server-authoritative activity performed by one Actor. Game code supplies a factory describing its requirements and behavior; KRF decides whether it can start and owns its active lifetime, locks, upfront payment, and declarative Tag cleanup.

Attacks, holds, channels, sprinting, modes, and transformations all use this model. Their differences come from callbacks and metadata, not separate Action classes or kinds.

## A complete Action

This Dodge spends Stamina, holds `Movement`, and exposes `Status.Dodging` until it Ends. The example establishes a gameplay window; your movement and presentation code supplies the actual dodge motion and visuals.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)

local function createDodge(): ActionTypes.ActionDefinition
	return {
		id = "Action.Dodge",
		visibility = "ServerOnly",
		autoGrant = true,
		costs = { ["Resource.Stamina"] = 15 },
		locks = { "Movement" },
		activeTags = { "Status.Dodging" },
		onStart = function(ctx: ActionTypes.ActionExecutionContext): ()
			task.wait(0.25)
			ctx:End()
		end,
	}
end

local started, failure = Server.Init({
	actions = { createDodge },
	tags = {
		{ id = "Status.Dodging", visibility = "ServerOnly", duplicateBehavior = "Stack" },
	},
	resources = {
		{ id = "Resource.Stamina", visibility = "ServerOnly", max = { value = 100 }, autoAssign = true },
	},
})
if not started then
	assert(failure ~= nil)
	error(`KRF startup failed: {failure.system}: {failure.reason}`)
end
```

`onStart` supports yielding, including `task.wait`. KRF tracks its suspended invocation and retires it if the Action is externally Ended, Interrupted, or destroyed. Other Action hooks must finish without yielding; see [hook contracts](./action-lifecycle#hook-contracts).

Registration defines the Action. A grant authorizes requests. Acceptance creates an activation. Returning from `onStart` does not End it: use `ctx:End()` for completion or `ctx:Interrupt(reason)` for cancellation.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `ActionRegistry` | Frozen static metadata loaded at startup. |
| Actor's `ActionController` | Grants, request decisions, activation identity, locks, termination, and optional updates. |
| `TagController` | Status presence, stacks, expiry, and Tag applications. |
| `PropertyController` | Numeric base values and resolved values after Tag modifiers. |
| `ResourceController` | Current meters, bounds, spending, and regeneration, including cooldowns and charges. |
| Action author | Definitions, private activation state, game-specific decisions, and behavior inside callbacks. |

These guides cover Action definitions and their server lifecycle. `RequestAction` is a low-level server entrypoint for integrations and occasional server-driven behavior; direct calls are not the usual Action-authoring workflow. Input integration is outside this guide. `visibility` is metadata, not an input binding.

## Which KRF primitive should I use? {#which-primitive}

Use the declarative primitive when it expresses the requirement. Reserve callbacks for decisions and behavior that need game code.

| Gameplay intent | Primitive | Decision guidance |
| --- | --- | --- |
| Learned ability, equipped moveset, universal ability | [Grants](./action-grants): `SetGrants` or `autoGrant` | Authorizes requests; does not measure present readiness. |
| Must be grounded; cannot act while stunned | [Tags](./action-tags): `requiredTags` / `blockedTags` | Start-time status gates. Later changes need an explicit game reaction. |
| Require low Heat, a full meter, or one charge | [Resources](./action-resources): `resourceRequirements` | Inclusive start-time thresholds; does not spend. |
| Pay Stamina or Mana when accepted | [Resources](./action-resources): `costs` | Atomic upfront payment across all declared Resources. |
| Validate a target or a game-specific condition | [Lifecycle](./action-lifecycle): `onCanStart` | Non-yielding additional decision; use requirements/costs for Resource gating/payment. |
| Publish status while active; apply a lasting buff | [Tags](./action-tags): `activeTags` / `appliedTags` | Active contributions are cleaned up; applied effects follow Tag lifetime rules. |
| Prevent two Actions from using the same exclusive capability at once | [Locks](./action-locks): `locks` | Actions claiming the same lock cannot remain active together. |
| Allow a new Action to interrupt the current lock owner | [Preemption](./action-locks): `interruptibleBy` / `canBeInterruptedBy` | The owner lists permitted incoming Action ids; its optional hook can deny interruption. |
| Exclusive work during one phase | [Locks](./action-locks): `ctx:ClaimLocks` | Scoped, releasable ownership within an activation. |
| Charge progress, periodic channel work, ongoing drain | [Updates](./action-updates): `onUpdate` | Non-yielding elapsed-time work, at most 20 Hz. Use direct Resources for ongoing payment. |
| Player releases a held button | [Lifecycle](./action-lifecycle): `RequestStop` / `onStopRequested` | Delivers intent; the Action chooses release, continuation, or termination. |
| Activity completes normally | [Lifecycle](./action-lifecycle): `End` | Terminal completion and cleanup. |
| Activity is cancelled or disrupted | [Lifecycle](./action-lifecycle): `Interrupt` | Terminal interruption with a reason; explicit interruption bypasses lock preemption policy. |
| Recharge an ability or restore charges | [Resource-based cooldowns/charges](./action-patterns#cooldown) | Ordinary assigned Resources with requirements, costs, and regeneration. |

Do not introduce a parallel active-ability manager, cost checker, or lock table for behavior the Action runtime already owns. Per-activation private state belongs in factory-local variables; there is no `ctx.state` or consumer-owned `ActionInstance` class to implement.

## Learning path

1. [Defining Actions / Action Registry](./action-registry): factories and startup.
2. [Availability & Grants](./action-grants): access versus readiness.
3. [Action Lifecycle](./action-lifecycle): requests, callbacks, and termination.
4. [Action Tags](./action-tags) and [Action Resources](./action-resources): declarative gates and effects.
5. [Locks & Preemption](./action-locks) and [Action Updates](./action-updates): concurrent and ongoing work.
6. [Action Patterns / Recipes](./action-patterns): small implementations of common gameplay intents.
7. [Advanced Ordering & Reentrancy](./action-ordering): transaction and nested-callback guarantees.

For exact symbols, use the [ActionController](/api/Action/action-controller), [execution context](/api/Action/action-execution-context), and [public types](/api/Action/action-types) references.
