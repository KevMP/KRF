---
sidebar_position: 2
---

# Defining Actions / Action Registry

Define an Action with an `ActionFactory`: a non-yielding function returning an `ActionDefinition`. The definition declares requirements, effects, and callbacks; factory-local variables keep each activation's private state.

## Keep activation state in lexical locals

This Hold records elapsed time privately and releases on a Stop request. Each activation has a separate `heldSeconds` shared by its callbacks.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)

local function createHold(): ActionTypes.ActionDefinition
	local heldSeconds: number = 0
	return {
		id = "Action.Hold",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Hands" },
		onUpdate = function(_ctx: ActionTypes.ActionExecutionContext, deltaTime: number): ()
			heldSeconds += deltaTime
		end,
		onStopRequested = function(ctx: ActionTypes.ActionExecutionContext): ()
			-- Game code can use heldSeconds to choose the release outcome.
			print(`Held for {heldSeconds} seconds`)
			ctx:End()
		end,
	}
end
```

Register `createHold` as a factory, not `createHold()` as a definition. There is no mutable context state bag or consumer-owned instance class. Module-level mutable locals would be shared between activations; use them only for deliberately shared game state.

## Register the Action

Include `createHold` in the startup configuration's `actions` array. Referenced Tags and Resources belong in the same configuration. See [Initializing KRF](../initializing-krf) for setup and startup failures.

## Choose metadata by responsibility

| Metadata | Guide |
| --- | --- |
| `autoGrant` | [Availability & Grants](./action-grants) |
| `requiredTags`, `blockedTags`, `activeTags`, `appliedTags` | [Action Tags](./action-tags) |
| `resourceRequirements`, `costs` | [Action Resources](./action-resources) |
| `locks`, `interruptibleBy` | [Locks & Preemption](./action-locks) |
| Callbacks | [Action Lifecycle](./action-lifecycle#hook-contracts), [Action Updates](./action-updates) |

`id` must be unique and non-empty; `visibility` is required (`"ServerOnly"` or `"ClientVisible"`). Action references in `interruptibleBy` may refer forward or to the Action itself. KRF has no Action kind, static duration, priority, phase, or first-class cooldown field. Unsupported fields are rejected.

The [type reference](/api/Action/action-types#action-definition) owns exact shapes, defaults, and validation constraints.

## Read static metadata

Game code can use [`ActionRegistry.Get`](/api/Action/action-registry#get) for one definition, `GetAll` for declaration order, or `GetAllById` for keyed lookup. Loaded definitions contain no callbacks. All returned metadata and nested collections are frozen copies; modifying authored tables cannot change the catalog.

Registration does not grant or start an Action. Continue with [Availability & Grants](./action-grants).
