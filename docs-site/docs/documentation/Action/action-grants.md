---
sidebar_position: 3
---

# Availability & Grants

A grant authorizes an Actor to request a registered Action. Present readiness is decided separately by Tag requirements, Resource requirements and affordability, `onCanStart`, and lock availability.

| Question | Supported surface |
| --- | --- |
| Does the Action exist? | `ActionRegistry.Get(actionId)` |
| May this Actor request it? | `IsActionGranted(actionId)` / `GetGrantedActions()` |
| Can it start now? | `RequestAction(actionId, parameters)` returns an accepted or rejected result. There is no public readiness-preview API. |

## Baseline and source grants

Set `autoGrant = true` in the factory's static metadata for an Action available to every Actor. The controller applies this baseline at construction without a grant-change event. Auto-grant does not bind input or start an activation.

Use `SetGrants` for ownership supplied by equipment, progression, or a moveset. Each source replaces its own complete set; other sources remain intact.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)

local function equipMoveset(actor: ActorTypes.Actor, actionIds: { string }): boolean
	local actions = actor:GetController("ActionController") :: ActionTypes.ActionController
	local success, reason = actions:SetGrants("CurrentMoveset", actionIds)
	if not success then
		warn(`Moveset grant failed: {reason}`)
	end
	return success
end
```

Call this after Actor registration, using ids loaded at startup. A source id is an opaque, non-empty, case-sensitive string scoped to one Actor. An empty Action array clears the source. Duplicate ids collapse to one contribution.

For example, `Learned` and `CurrentMoveset` can both grant `Action.Fireball`. Removing it from `Learned` preserves access until `CurrentMoveset` also removes it. Explicit sources cannot revoke an auto-grant.

KRF validates the complete replacement before changing grant state. Failure preserves prior grants and emits no event. Success commits the entire set before notifying observers. Revocation prevents future starts but does not terminate existing activations; explicitly Interrupt them if the game requires that behavior.

## Observe effective access

`GetGrantedActions` returns a frozen snapshot in registry order; unknown ids return `false` from `IsActionGranted`. `OnActionGrantChanged(actor, actionId, isGranted)` reports only effective changes, so redundant contributions emit nothing. There is no promised ordering between changed ids in one reconciliation.

Persist learned ownership in game code and restore it through a source after Actor registration. Controller destruction clears grants and event connections without synthetic revocation events.

Use the [ActionController reference](/api/Action/action-controller#set-grants) for exact signatures and failure reasons. Continue with [Action Lifecycle](./action-lifecycle).
