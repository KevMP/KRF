---
sidebar_position: 1
---

# Action catalog

`ActionRegistry` owns the immutable server catalog of Action definitions. Supply `actions` to `Server.Init` alongside Tags and Resources; game code reads the catalog through the registry.

This surface stores static metadata only. Registration itself does not grant, activate, or execute an Action. The actor-scoped [`ActionController`](./action-grants) manages grant state from the loaded `autoGrant` baseline and explicit sources. Granting an Action does not execute hooks, acquire locks, spend Resources, or replicate Action state.

## Definition fields

Import `ActionDefinition` and `LoadedActionDefinition` from `KRF.server.Action.types` when typing authored and loaded definitions.

| Field | Contract |
| --- | --- |
| `id` | Required unique, non-empty string. |
| `visibility` | Required `"ServerOnly"` or `"ClientVisible"` replication metadata. |
| `autoGrant` | Optional boolean; defaults to `false`. Grants the Action to every Actor when its `ActionController` is created. It does not start the Action or bind input. |
| `requiredTags` | Optional array of registered Tag ids declaring preconditions. |
| `blockedTags` | Optional array of registered Tag ids declaring blockers. Cannot overlap `requiredTags`. |
| `costs` | Optional Resource-id keyed map of finite, strictly positive upfront cost amounts. |
| `locks` | Optional array of opaque, non-empty game-defined lifetime lock ids. Locks declare concurrency claims. |
| `interruptibleBy` | Optional array of exact Action ids permitted to preempt this Action. Forward references and self-references are valid. |
| `onCanStart` | Optional function returning `(boolean, string?)`, for an Action-defined start decision. |
| `onStart`, `onUpdate`, `onEnd`, `onInterrupt` | Optional lifecycle functions. |
| `canBeInterruptedBy` | Optional function returning `boolean`, refining the static `interruptibleBy` allowlist. |

All lists must be dense arrays without duplicate entries. Their entries must be non-empty strings. Tag and Resource references must exist in the same startup configuration; Action references resolve against the complete Action catalog. Omitted lists and `costs` normalize to empty collections.

KRF has no Action kind taxonomy, static duration, or first-class cooldown metadata. Cooldowns and charges belong in [Resources](../Resource/resource-runtime). Phases, combos, input buffers, priorities, categories, and other unsupported fields are rejected.

All lifecycle hooks are optional; their presence does not define the framework-owned lifecycle. Missing `onCanStart` declares no additional Action-defined rejection; missing `onStart`, `onEnd`, or `onInterrupt` declares no custom behavior for that transition. Missing `onUpdate` does not opt into stepping. Returning from `onStart` does not specify Action lifetime. The preemption hook refines permission only after the incoming id passes `interruptibleBy`.

The catalog preserves hook functions without invoking them. Callback arguments are typed as `...any`; this catalog exposes no execution-context capabilities.

## Configure the catalog

This startup example declares an auto-granted Dodge with Tag preconditions, a Stamina cost, a lifetime lock, and a forward interruption reference to Roll.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)

local actions: { ActionTypes.ActionDefinition } = {
	{
		id = "Action.Dodge",
		visibility = "ClientVisible",
		autoGrant = true,
		requiredTags = { "Status.Grounded" },
		blockedTags = { "Status.Stunned" },
		costs = { ["Resource.Stamina"] = 15 },
		locks = { "Locomotion" },
		interruptibleBy = { "Action.Roll" },
	},
	{ id = "Action.Roll", visibility = "ClientVisible" },
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

`Server.Init` validates all catalogs before publication. An Action error returns `false, { system = "Action", reason = ... }` and leaves every catalog unpublished. Reasons identify the field and rule, such as `ActionIdAlreadyRegistered`, `ActionRequiredTagUnknown:Status.Grounded`, or `ActionCostMustBePositive`. Correct the configuration and restart after a failed startup attempt.

Validation checks catalog shape and unique ids before validating definitions in declaration order. Field checks use a fixed order; Resource cost keys and unsupported field names are checked alphabetically. Reference validity does not depend on declaration order.

After successful startup, `GetAll()` preserves declaration order, `GetAllById()` provides keyed lookup, and `Get(id)` returns a definition or `nil`. The definitions, nested collections, and catalog read tables are frozen. Loading copies authored data, so later edits to source tables cannot change the catalog. Hooks retain their function identity; freezing definitions does not freeze state captured by a callback.

Omitting `actions` loads an empty catalog with `IsLoaded() == true`. Before publication, queries return empty frozen collections or `nil`, and `IsLoaded()` is `false`.

## Related

- [Action Registry API](/api/Action/action-registry)
- [Action grants](./action-grants)
- [Initializing KRF](../initializing-krf)
- [Tag Registry](../Tags/tag-registry)
- [Resource Registry](../Resource/resource-registry)
