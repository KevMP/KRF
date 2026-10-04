---
sidebar_position: 1
---

# Action Registry

`ActionRegistry` owns immutable server definitions for Actions. Supply Action factories in `actions` to `Server.Init` alongside Tags and Resources; game code reads their static metadata through the registry.

This surface stores static metadata only. Registration itself does not grant, activate, or execute an Action. The actor-scoped [`ActionController`](./action-grants) manages grant state from the loaded `autoGrant` baseline and explicit sources. Granting an Action does not execute hooks, acquire locks, spend Resources, or replicate Action state.

## Definition fields

Import `ActionDefinition` and `LoadedActionDefinition` from `KRF.server.Action.types` when typing authored and loaded definitions. `LoadedActionDefinition` contains only static metadata; callbacks are not available from registry reads.

| Field | Contract |
| --- | --- |
| `id` | Required unique, non-empty string. |
| `visibility` | Required `"ServerOnly"` or `"ClientVisible"` replication metadata. |
| `autoGrant` | Optional boolean; defaults to `false`. Grants the Action to every Actor when its `ActionController` is created. It does not start the Action or bind input. |
| `requiredTags` | Optional array of registered Tag ids recorded as requirement metadata. |
| `blockedTags` | Optional array of registered Tag ids recorded as blocker metadata. Cannot overlap `requiredTags`. |
| `costs` | Optional Resource-id keyed map of finite, strictly positive cost metadata. |
| `locks` | Optional array of opaque, non-empty game-defined lock ids, acquired as [lifetime claims](./action-locks) at activation. |
| `interruptibleBy` | Optional array of exact Action ids permitted to preempt this Action when locks conflict. Forward references and self-references are valid. |
| `onCanStart` | Optional function returning `(boolean, string?)`, for an Action-defined start decision. |
| `onStart`, `onStopRequested`, `onEnd`, `onInterrupt` | Optional lifecycle functions. |
| `onUpdate` | Optional `(ActionExecutionContext, number) -> ()` hook for [active Action updates](./action-updates). |
| `canBeInterruptedBy` | Optional `(ActionExecutionContext, ActionInterruptionContext) -> boolean` hook from the running instance, narrowing the static `interruptibleBy` allowlist. |

All lists must be dense arrays without duplicate entries. Their entries must be non-empty strings. Tag and Resource references must exist in the same startup configuration; Action references resolve against the complete Action registry. Omitted lists and `costs` normalize to empty collections.

These fields are validated and stored at startup. The current `ActionController` does not evaluate `requiredTags` or `blockedTags` against an Actor, or spend `costs`, when handling `RequestAction`. See [Action Runtime](./action-lifecycle) for the request decision order.

KRF has no Action kind taxonomy, static duration, or first-class cooldown metadata. Cooldowns and charges belong in [Resources](../Resource/resource-runtime). Phases, combos, input buffers, priorities, categories, and other unsupported fields are rejected.

All lifecycle hooks are optional; their presence does not define the framework-owned lifecycle. Missing `onCanStart` declares no additional Action-defined rejection; missing `onStart`, `onEnd`, or `onInterrupt` declares no custom behavior for that transition. Missing `onUpdate` does not opt into stepping. Returning from `onStart` does not specify Action lifetime. The preemption hook refines permission only after the incoming id passes `interruptibleBy`.

KRF calls each factory once at startup to load metadata, then once for each granted request that reaches Action-defined validation. Keep `id`, `visibility`, grants, tags, costs, locks, and interruption metadata fixed. The startup values control the registry; per-request results provide fresh callbacks and private lexical state. `onCanStart` receives an `ActionStartContext`; lifecycle callbacks receive an [`ActionExecutionContext`](./action-lifecycle#execution-context) when an Actor runs the Action.

KRF captures the returned callback references for each request before `onCanStart` runs. Changing fields on a returned table afterward does not change an active Action's callbacks.

## Configure the registry

This startup example declares an auto-granted Dodge with Tag and Stamina metadata, a lifetime lock, and a forward interruption reference to Roll.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)

local actions: { ActionTypes.ActionFactory } = {
	function(): ActionTypes.ActionDefinition
		return {
			id = "Action.Dodge",
			visibility = "ClientVisible",
			autoGrant = true,
			requiredTags = { "Status.Grounded" },
			blockedTags = { "Status.Stunned" },
			costs = { ["Resource.Stamina"] = 15 },
			locks = { "Locomotion" },
			interruptibleBy = { "Action.Roll" },
		}
	end,
	function(): ActionTypes.ActionDefinition
		return { id = "Action.Roll", visibility = "ClientVisible" }
	end,
}

local started: boolean, failure: Server.StartupFailure? = Server.Init({
	tags = {
		{ id = "Status.Grounded", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
		{ id = "Status.Stunned", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
	},
	resources = {
		{ id = "Resource.Stamina", visibility = "ServerOnly", max = { value = 100 }, autoAssign = true },
	},
	actions = actions,
})
if not started then
	assert(failure ~= nil)
	error(`KRF startup failed: {failure.system}: {failure.reason}`)
end
```

## Validation and reads

`Server.Init` validates all registries before publication. An Action error returns `false, { system = "Action", reason = ... }` and leaves every registry unpublished. Reasons identify the field and rule, such as `ActionIdAlreadyRegistered`, `ActionRequiredTagUnknown:Status.Grounded`, or `ActionCostMustBePositive`. Correct the configuration and restart after a failed startup attempt.

Validation calls factories without yielding, then checks definition shape and unique ids before validating definitions in declaration order. A factory error or yield fails startup. Field checks use a fixed order; Resource cost keys and unsupported field names are checked alphabetically. Reference validity does not depend on declaration order.

After successful startup, `GetAll()` preserves declaration order, `GetAllById()` provides keyed lookup, and `Get(id)` returns static metadata or `nil`. The metadata, nested collections, and registry read tables are frozen. Loading copies authored data, so later edits to source tables cannot change the registry.

Omitting `actions` loads an empty registry with `IsLoaded() == true`. Before publication, queries return empty frozen collections or `nil`, and `IsLoaded()` is `false`.

## Related

- [Action Registry API](/api/Action/action-registry)
- [Action Grants](./action-grants)
- [Action Runtime](./action-lifecycle)
- [Action Updates](./action-updates)
- [Action Locks](./action-locks)
- [Action Example](./action-example)
- [Initializing KRF](../initializing-krf)
- [Tag Registry](../Tags/tag-registry)
- [Resource Registry](../Resource/resource-registry)
