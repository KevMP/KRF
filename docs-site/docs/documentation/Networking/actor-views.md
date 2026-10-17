---
sidebar_position: 4
---

# Client ActorViews

An ActorView is one Actor's current server-authoritative state visible to this client. Use it for UI and presentation; gameplay mutations stay in server controllers.

`Client.Init()` installs the view runtime automatically. A view appears only after its complete initial baseline validates. Subscribe to `ActorViewRegistry.OnActorViewAdded` for future Actors and inspect `GetAllActorViews()` for Actors already available when your system starts.

## Find and retain a view

Import `KRF.client.Actor.ActorViewRegistry`. Lookup by public actorId or by its currently bound Roblox Model returns the same ActorView. Unknown or unavailable identities return `nil`. The registry and its lookup methods are immutable; `GetAllActorViews()` returns an independent collection.

| Lifetime change | Observable behavior |
| --- | --- |
| Initial baseline completes | A complete view enters the registry; Added fires once |
| Model arrives or streams out | `GetModel()` changes and `OnModelChanged(previous, current)` fires; the view and its state remain |
| Replacement baseline arrives | The same view receives current truth; retained visible domains keep their identity and subscriptions |
| Owner visibility changes | Replacement adds newly visible domains and retires domains no longer visible |
| Authoritative Actor removal | Removing fires once; registry membership and owned domain/Model signals are released |
| Respawn | A new actorId creates a distinct view |

Use the supplied view as the identity in removal callbacks. Signal handlers may run after registry membership has already been removed. Retired DomainViews return no old state and reject new subscriptions through their retained events; a domain that becomes visible again receives a new DomainView.

## Read domains and observe changes

`view:GetDomain("Game.Stamina")` returns a generic DomainView when that domain is visible. Unknown or invisible domains return `nil`; a visible Optional domain may legitimately have `GetState() == nil`. `GetDomainIds()` returns the visible ids in deterministic order.

`domain:GetState()` returns complete, recursively immutable truth. Nested Structs, Maps and Arrays are protected, and retained snapshots remain historical values after later changes. Do not modify them or attach client prediction to them; keep cosmetic local state separately.

| Observation | Use |
| --- | --- |
| Current `GetState()` | Initialize or reconcile persistent UI and effects |
| `OnChanged(change)` | React to a changed complete state; `change` contains immutable `previous`, `current` and `source` |
| `GetEvent(eventId)` | React to a declared occurrence; unknown event ids return `nil` |

One logical commit installs all changed domain states before any public notification. Changed-domain signals fire in domain-id order, followed by semantic events in their authoritative order. An event-only commit can fire semantic events without firing `OnChanged`. Composite event payloads are immutable too.

KRF Signals are yield-safe. State is installed before `Fire`, but a handler that runs or resumes later may observe a newer state. Use an event's payload or `change.previous`/`change.current` for transition-specific information. A throwing or yielding handler does not roll back authoritative application.

## Initial state and recovery

Initial creation fires Added without synthetic domain changes or historical semantic events. Initialize from current state when attaching to a view.

If an Actor's stream becomes discontinuous or an update cannot be applied, its last complete valid truth remains available while Networking requests a replacement baseline. Incremental history is discarded while waiting. Other Actors and Model binding continue independently.

A valid replacement atomically reconciles values and the complete visible domain set. Changed retained domains fire `OnChanged` with `source = "Baseline"`; live changes use `"Commit"`. Replacement does not replay semantic history. Reconcile persistent effects from state instead of expecting missed occurrences to replay. Repeated invalid recovery data emits diagnostics without an immediate retry loop.

A terminal stream halt invalidates the affected Actor's domain truth and stops recovery. Its identity and Model lifecycle remain until authoritative removal. Connection handles, revisions, baseline generations, transport and recovery controls are private Networking details.

## Complete custom-domain client example

This LocalScript consumes `Game.Stamina` from the [server controller/domain example](./replication-domains#committed-observation-callback-contract). That example declares state `{ current: number }` and no semantic events. No additional client networking adapter is required.

```lua title="Stamina.client.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Client = require(KRF.client)
local ClientTypes = require(KRF.client.types)
local ViewTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Registry = require(KRF.client.Actor.ActorViewRegistry)

local bindings: { [ViewTypes.ActorView]: SignalTypes.Connection } = {}
local function attach(view: ViewTypes.ActorView): ()
	if bindings[view] ~= nil then
		return
	end
	local stamina: ViewTypes.DomainView? = view:GetDomain("Game.Stamina")
	if stamina == nil then
		return
	end
	print(view:GetId(), "stamina", stamina:GetState().current)
	bindings[view] = stamina.OnChanged:Connect(function(change: ViewTypes.DomainChange)
		print(view:GetId(), "stamina", change.current.current, change.source)
	end)
end

local added: SignalTypes.Connection = Registry.OnActorViewAdded:Connect(attach)
local removing: SignalTypes.Connection = Registry.OnActorViewRemoving:Connect(function(view: ViewTypes.ActorView)
	local connection: SignalTypes.Connection? = bindings[view]
	if connection ~= nil then
		connection:Disconnect()
		bindings[view] = nil
	end
end)

local started: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
if not started then
	added:Disconnect()
	removing:Disconnect()
	error(if failure ~= nil then failure.system .. ": " .. failure.reason else "Client startup failed")
end
for _, view: ViewTypes.ActorView in Registry.GetAllActorViews() do
	attach(view)
end

script.Destroying:Connect(function()
	added:Disconnect()
	removing:Disconnect()
	for _, connection: SignalTypes.Connection in bindings do
		connection:Disconnect()
	end
	table.clear(bindings)
end)
```

Generic domains are the extension surface for game-defined state. Typed convenience APIs for built-in gameplay systems are separate from this generic view contract.

## Related

- [ActorView Registry API](/api/Actor/actor-view-registry)
- [ActorView API](/api/Actor/actor-view)
- [DomainView API](/api/Actor/domain-view)
- [Actor replication lifecycle](./actor-replication)
