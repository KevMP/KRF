---
sidebar_position: 2
---

# Action grants

KRF attaches an `ActionController` to each registered Actor as its Action runtime. This guide covers its grant state: which registered Actions that Actor has been granted.

| System | Responsibility |
| --- | --- |
| `ActionRegistry` | Stores loaded Action definitions. A definition's presence alone grants no Actor access. |
| `ActionController` grant state | Combines the `autoGrant` baseline with that Actor's explicit grant sources. |

A grant is authorization, not an active Action. Grant queries do not decide whether an Action can start under current runtime conditions.

An Action with `autoGrant = true` is granted when each Actor's controller is created. Define the baseline alongside other registered Actions at startup:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActionTypes = require(KRF.server.Action.types)

local definitions: { ActionTypes.ActionDefinition } = {
	{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true },
	{ id = "Action.Fireball", visibility = "ServerOnly" },
	{ id = "Action.WaterDragon", visibility = "ServerOnly" },
	{ id = "Action.Substitution", visibility = "ServerOnly" },
}
local started: boolean, failure: Server.StartupFailure? = Server.Init({ actions = definitions })
if not started then
	assert(failure ~= nil)
	error(`KRF startup failed: {failure.system}: {failure.reason}`)
end
```

Auto-grant does not bind input or start the Action. Construction emits no grant-change event.

## Reconcile source sets

Game systems provide complete sets of Action ids through [`SetGrants`](/api/Action/action-controller#set-grants). A source id is an opaque, non-empty, case-sensitive string scoped to one Actor. KRF stores and compares it without interpreting names such as `"Learned"` or `"CurrentMoveset"`.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)

type Actor = ActorTypes.Actor

ActorRuntime.OnActorRegistered:Connect(function(actor: Actor)
	local actionController: ActionTypes.ActionController = actor:GetController("ActionController") :: ActionTypes.ActionController

	local function reconcile(sourceId: string, actionIds: { string }): ()
		local success: boolean, reason: string? = actionController:SetGrants(sourceId, actionIds)
		if not success then
			error(`Action grant reconciliation failed: {reason}`)
		end
	end

	reconcile("Learned", { "Action.Fireball", "Action.WaterDragon" })
	reconcile("CurrentMoveset", { "Action.Fireball", "Action.Substitution" })
	reconcile("Learned", { "Action.WaterDragon" })
	-- Fireball remains granted by CurrentMoveset.
	reconcile("CurrentMoveset", {})
	-- Fireball and Substitution are now revoked; WaterDragon remains granted.
end)
```

`SetGrants` replaces only the named source's previous set. Repeated ids collapse to one contribution, and input order has no meaning. An empty list clears that source; clearing an absent source succeeds without an event. Multiple sources may grant the same Action, and explicit sources may include an auto-granted Action without changing its effective state.

KRF validates the source id, array shape, entries, and registry membership before replacing anything. A failed call returns `false, reason`, preserves all prior grants, and fires no event. On success, the complete new state is committed before any grant-change event fires.

## Read and observe effective grants

An Action is effectively granted when `autoGrant` is true or at least one explicit source includes it. `IsActionGranted` returns `false` for an unknown id. `GetGrantedActions` returns each effective id once in Action catalog order as a frozen snapshot. An effective grant change publishes a new snapshot on the next read without changing an earlier one.

`OnActionGrantChanged` reports `(actor, actionId, isGranted)` only when effective access changes. Adding or removing a redundant source contribution produces no event. A callback can query the fully committed grant set; callbacks for multiple changed Actions have no promised order.

Grants are runtime state. Game persistence code can restore ownership by calling `SetGrants` with its own source id after Actor registration. Destroying the controller clears explicit state and its event connections without emitting revocations.

## Related

- [ActionController API](/api/Action/action-controller)
- [Action catalog](./action-registry)
- [Initializing KRF](../initializing-krf)
