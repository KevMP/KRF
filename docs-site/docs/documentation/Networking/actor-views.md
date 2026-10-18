---
sidebar_position: 4
---

# Client ActorViews

An ActorView is one Actor's current server-authoritative state visible to this client. Use it for UI and presentation; gameplay mutations stay in server controllers.

`Client.Init()` installs the view runtime automatically. A view appears only after its complete initial baseline validates. Subscribe to `ActorViewRegistry.OnActorViewAdded` for future Actors and inspect `GetAllActorViews()` for Actors already available when your system starts.

## Find and retain a view

Import `KRF.client.Actor.ActorViewRegistry`. Lookup by public actorId or by its currently bound Roblox Model returns the same ActorView. Unknown, not-yet-published, or removed identities return `nil`; terminally halted views remain registered until removal. The registry and its lookup methods are immutable; `GetAllActorViews()` returns an independent collection.

| Lifetime change | Observable behavior |
| --- | --- |
| Initial baseline completes | A complete view enters the registry; Added fires once |
| Model arrives or streams out | `GetModel()` changes and `OnModelChanged(previous, current)` fires; the view and its state remain |
| Replacement baseline arrives | The same view receives current truth; retained visible domains keep their identity and subscriptions |
| Visible domains change | `OnDomainsChanged` reports added/removed ids after replacement installs the complete domain set |
| Terminal failure | Domain truth is retired, `IsAvailable()` becomes false, then `OnUnavailable` fires; identity and Model binding remain |
| Authoritative Actor removal | Removing fires once; registry membership and owned domain/Model signals are released |
| Respawn | A new actorId creates a distinct view |

Use the supplied view as the identity in removal callbacks. Signal handlers may run after registry membership has already been removed. Retired DomainViews return no old state and reject new subscriptions through their retained events; a domain that becomes visible again receives a new DomainView.

## Read domains and observe changes

`view:GetDomain("Game.Stamina")` returns a generic DomainView when that domain is visible. Unknown or invisible domains return `nil`; a visible Optional domain may legitimately have `GetState() == nil`. `GetDomainIds()` returns the visible ids in deterministic order. To check a retained domain, use `view:GetDomain(domain:GetId()) == domain`; state being `nil` does not distinguish an Optional value from retirement.

`domain:GetState()` returns complete, recursively immutable truth. Nested Structs, Maps and Arrays are protected, and retained snapshots remain historical values after later changes. Do not modify them or attach client prediction to them; keep cosmetic local state separately.

| Observation | Use |
| --- | --- |
| Current `GetState()` | Initialize or reconcile persistent UI and effects |
| `OnChanged(change)` | React to a changed complete state; `change` contains immutable `previous`, `current` and `source` |
| `GetEvent(eventId)` | React to a declared occurrence; unknown event ids return `nil` |

One logical commit installs all changed domain states before any public notification. Changed-domain signals fire in domain-id order, followed by semantic events in their authoritative order. An event-only commit can fire semantic events without firing `OnChanged`. Composite event payloads are immutable too.

Replacement installs all state and membership, then retires removed DomainViews before firing `OnDomainsChanged`. Its immutable `added` and `removed` arrays contain sorted domain ids. Membership fires before retained-domain `OnChanged` notifications, even when no retained value changed. Equal membership emits no event; new domains have current state without synthetic change events. A live view may have no visible domains.

KRF Signals are yield-safe. State is installed before `Fire`, but a handler that runs or resumes later may observe a newer state. Use an event's payload or `change.previous`/`change.current` for transition-specific information. A throwing or yielding handler does not roll back authoritative application.

## Initial state and recovery

Initial creation fires Added without synthetic domain changes or historical semantic events. Initialize from current state when attaching to a view.

If an Actor's stream becomes discontinuous or an update cannot be applied, its last complete valid truth remains available while Networking requests a replacement baseline. Incremental history is discarded while waiting. Other Actors and Model binding continue independently.

A valid replacement atomically reconciles values and the complete visible domain set. Changed retained domains fire `OnChanged` with `source = "Baseline"`; live changes use `"Commit"`. Replacement does not replay semantic history. Reconcile persistent effects from state instead of expecting missed occurrences to replay. Repeated invalid recovery data emits diagnostics without an immediate retry loop.

Recovery has five request opportunities: immediately, then after 1, 3, 7, and 15 elapsed seconds. A failed send or a silently rejected request consumes that opportunity. Client admission limits traffic across Actors and across repeated episodes for one Actor; a suppressed opportunity is not queued. A valid replacement cancels the episode. Repeated invalid data cannot restart its budget.

After the 31-second recovery budget expires, Networking reports failure and makes only that ActorView terminally unavailable. Timers run when Roblox schedules them; a paused client cannot receive a wall-clock callback guarantee. Recovery is bounded, not guaranteed to succeed under sustained overload or incompatible state. It retains no incremental history and uses no per-frame polling.

A terminal stream halt invalidates the affected Actor's domain truth and stops recovery. It clears membership and marks availability false before firing membership changes, then `OnUnavailable` once. `IsAvailable()` remains true during recoverable desync, when the last valid truth is retained. A terminally unavailable view cannot regain domain truth; its identity and Model lifecycle remain until authoritative removal. Removal uses the registry's Removing event and does not synthesize terminal-failure or membership events. All view-owned signals retire on removal.

Removing a view from a notification callback retires its signals and suppresses later notifications for that view. Use registry Removing to release the Actor's consumer lifetime, and membership changes to release or attach domain-specific bindings.

Malformed physical framing is reported and the entire packet is discarded, without guessing which Actor caused it. No partial record is applied. Once records decode, an Actor-local assembly fault requests recovery for that Actor while unrelated records continue. A later revision gap also enters normal recovery; a malformed packet alone does not declare every Actor unavailable.

Connection handles, revisions, baseline generations, transport and recovery controls are private Networking details.

## Complete custom-domain client example

This ModuleScript consumes `Game.Stamina` from the [server controller/domain example](./replication-domains#committed-observation-callback-contract). That example declares state `{ current: number }` and no semantic events. Call `Start()` from your sole client startup owner after `Client.Init()` succeeds. The consumer never initializes KRF itself.

```lua title="Stamina.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ViewTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Registry = require(KRF.client.Actor.ActorViewRegistry)

local Stamina = {}
function Stamina.Start(): () -> ()
	type Binding = { domain: ViewTypes.DomainView?, state: SignalTypes.Connection?, membership: SignalTypes.Connection? }
	local bindings: { [ViewTypes.ActorView]: Binding } = {}
	local function detach(view: ViewTypes.ActorView): ()
		local binding: Binding? = bindings[view]
		if binding == nil then
			return
		end
		if binding.state ~= nil then binding.state:Disconnect() end
		if binding.membership ~= nil then binding.membership:Disconnect() end
		bindings[view] = nil
	end
	local function attach(view: ViewTypes.ActorView): ()
		if bindings[view] ~= nil or not view:IsAvailable() then
			return
		end
		local binding: Binding = {}
		bindings[view] = binding
		local function reconcile(): ()
			local domain: ViewTypes.DomainView? = view:GetDomain("Game.Stamina")
			if domain == binding.domain then return end
			if binding.state ~= nil then binding.state:Disconnect() end
			binding.domain = domain
			binding.state = nil
			if domain == nil then
				print(view:GetId(), "stamina unavailable")
				return
			end
			print(view:GetId(), "stamina", domain:GetState().current)
			binding.state = domain.OnChanged:Connect(function(change: ViewTypes.DomainChange)
				print(view:GetId(), "stamina", change.current.current, change.source)
			end)
		end
		binding.membership = view.OnDomainsChanged:Connect(reconcile)
		reconcile()
	end
	local added: SignalTypes.Connection = Registry.OnActorViewAdded:Connect(attach)
	local removing: SignalTypes.Connection = Registry.OnActorViewRemoving:Connect(detach)
	for _, view: ViewTypes.ActorView in Registry.GetAllActorViews() do attach(view) end
	return function(): ()
		added:Disconnect()
		removing:Disconnect()
		for view: ViewTypes.ActorView in bindings do detach(view) end
	end
end
return Stamina
```

In `Startup.client.luau`, after the successful initialization shown in [Initializing KRF](../initializing-krf), require the sibling ModuleScript and retain its cleanup:

```lua
local Stamina = require(script.Parent.Stamina)
local stopStamina: () -> () = Stamina.Start()
script.Destroying:Connect(stopStamina)
```

Generic domains are the extension surface for game-defined state. Client code uses the domain and event ids registered by the server.

## Related

- [ActorView Registry API](/api/Actor/actor-view-registry)
- [ActorView API](/api/Actor/actor-view)
- [DomainView API](/api/Actor/domain-view)
- [Actor replication lifecycle](./actor-replication)
