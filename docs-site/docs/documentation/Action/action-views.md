---
sidebar_position: 11
---

# Client Action views

Use `actorView:GetActions()` to read current active visible Actions and observe their live lifecycle for presentation and UI. Server ActionController remains authoritative for requests, costs and termination.

## Read current activations

For an initialized client, acquire the ActorView through the registry:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local Types = require(KRF.client.Actor.types)

-- Called with an Actor's locally available Model.
local function inspect(model: Model): ()
	local actor: Types.ActorView? = Registry.GetActorViewByModel(model)
	if actor == nil then
		return
	end
	local actions: Types.ActionsView = actor:GetActions()
	for _, action: Types.ActionSnapshot in actions:GetActiveActions() do
		print(action.actionId, action.sequenceId)
	end
	print("Blocking:", actions:IsActionActive("Action.Block"))
end
```

Each activation has an immutable `ActionSnapshot` containing only `actionId` and `sequenceId`. Several instances of one Action id may be active simultaneously. `IsActionActive(id)` stays true until the last matching instance leaves; use `GetAction(sequenceId)` for exact identity. `GetActiveActions()` returns a frozen list sorted by ascending sequence id.

Bind client systems through [ActorViewRegistry lifecycle events](/api/Actor/actor-view-registry), and inspect current activations when binding to a new ActorView. A Model may be unavailable while the view remains live.

## Choose visible definitions

Set `visibility = "ClientVisible"` in an [Action factory](./action-registry) to publish its active instances and lifecycle to aware clients. `ServerOnly` Action ids are excluded from the bootstrap catalog, current state and lifecycle events. A private Action can still cause visible effects, including interrupting a visible owner.

KRF generates the reserved `KRF.Actions` domain from the validated visible catalog. Games must not define this domain themselves. With no visible definitions, the protocol omits it and every ActorView still supplies a stable empty ActionsView.

The projection excludes request parameters, server interruption reasons, grants, locks, execution state and arbitrary metadata. Put static animation or effect mappings in your presentation system, keyed by Action id. Read Tags and Resources through their own typed views.

## Current truth and lifecycle history {#history}

For an already acquired `actions: Types.ActionsView`, observe exact activations:

```lua
actions.OnActionStarted:Connect(function(action: Types.ActionSnapshot)
	print("Started", action.actionId, action.sequenceId)
end)
actions.OnActionEnded:Connect(function(action: Types.ActionSnapshot)
	print("Ended", action.actionId, action.sequenceId)
end)
actions.OnActionInterrupted:Connect(function(action: Types.ActionSnapshot)
	print("Interrupted", action.actionId, action.sequenceId)
end)
```

These are semantic occurrences, independent of current-state diffs. An Action that starts and immediately ends still reports Started followed by Ended, even if both transitions arrive in one physical packet and current state is already empty afterward. Ended and Interrupted remain distinct.

Each logical commit installs the complete resulting Action, Tag and Resource state before firing lifecycle events. Accepted costs, owned Tag cleanup, incoming Tags and activation become visible coherently. Authored hooks run after that boundary; immediate hook-driven termination creates a separate logical commit.

KRF Signals schedule listeners yield-safely. A Started handler that executes or resumes after a later terminal commit may find `actions:GetAction(action.sequenceId) == nil`. The event identifies the historical activation; queries always read current truth. Retained snapshots do not acquire an `active` flag or update themselves.

## Bind and recover persistent presentation

Initial baselines expose current activations without synthetic Started events. Replacement baselines preserve the same ActionsView and subscriptions, replace current truth atomically, and replay no lifecycle history. Differing state emits `OnStateChanged("Baseline")`; equal replacement emits nothing. Live state changes use `"Commit"`.

Initialize persistent effects from `GetActiveActions()` and reconcile them on state changes. Use lifecycle events for live occurrences. Missed Starts or terminal events are not replayed after recovery or overload, so persistent cleanup must also follow current state.

Model streaming changes visual binding independently of Action state. Actor removal empties and retires the view and its events; a respawn gets a new ActorView and ActionsView. Release consumer subscriptions with the ActorView's registry lifetime.

## Supported bounds

Sequence ids are unique, monotonic positive integers from 1 through 4,294,967,295 within one ActionController lifetime. ServerOnly instances share that namespace. Exhaustion rejects new requests with `ActionSequenceIdExhausted` before costs, Tags or preemption.

At most 256 ClientVisible instances may be active on one Actor. Admission accounts for visible owners that the incoming Action will preempt; ServerOnly owners do not free visible slots. Exceeding the resulting bound rejects with `ActionVisibleInstanceLimitReached`, without partial payment or effects. Terminal paths never automatically refund accepted costs.

ActionsView provides observation only. Client Action command transport and request/result correlation are not available here; a future accepted request result will correlate with the same authoritative sequence identity. Do not treat replicated activity as a local grant or permission to mutate gameplay.

## Related

- [ActionsView API](/api/Actor/actions-view)
- [Client ActorViews](../Networking/actor-views)
- [Action ordering](./action-ordering)
