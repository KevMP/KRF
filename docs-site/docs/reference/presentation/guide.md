---
title: Presentation
sidebar_label: Guide
---

# Presentation

Register a client Presentation to start your own visual code when KRF delivers an Action, Tag, Resource or Hint event, or while an Actor is in an active Tag or Action state. Each matching event, and each active state occurrence, starts an independent instance for each definition. KRF finds the originating ActorView, scopes subscriptions to that view, and runs the cleanup you register. Every type, form and failure reason is listed in the [Presentation API](./api).

## Highlight an Actor when an Action starts

With a KRF runtime and generator that include Presentation, scaffold a definition for a client-visible Action. This example listens for `Sword.Swing` on any Actor whose Action events reach the client.

```bash
npm run createPresentation -- --name SwingHighlight --id Sword.Swing.Highlight --event Action.Started --source-id Sword.Swing --yes
```

Open `src/client/Presentations/Sword/Swing/SwingHighlight.luau` and give its `create` function a Roblox `Highlight`. The server needs a [client-visible Action](../actions/guide) with the matching ID.

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local SwingHighlight: KRF.PresentationDefinition = {
	id = "Sword.Swing.Highlight",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Sword.Swing" },
	create = function(ctx)
		local actor = ctx.actor
		local model = if actor ~= nil then actor:GetModel() else nil

		if model == nil then
			ctx:Finish()
			return
		end

		local highlight = Instance.new("Highlight")
		highlight.Adornee = model
		highlight.Parent = model
		ctx:Own(function()
			highlight:Destroy()
		end)

		task.delay(0.4, function()
			if ctx:IsActive() then
				ctx:Finish()
			end
		end)
	end,
}

return SwingHighlight
```

The effect can overlap with another swing, even on the same Actor. `Finish` retires just that instance. An Action end or interruption leaves existing instances active until they finish or their ActorView retires. If you want a visual to start on an Action end, register a definition for `KRF.PresentationEvents.Action.Ended`.

## Register definitions

The first generated Presentation adds `src/client/Presentations/init.luau` and wires that catalog into `Startup.client.luau`. The loader collects the definitions under `Presentations`, including namespaced subfolders. Add future definitions as ModuleScripts in that folder. If you maintain a custom startup, require the catalog and pass it as `presentations` in your existing `KRF.Client.Init` call.

Each definition has a unique `id`, one `entry` binding and a `create(ctx)` function. The binding pairs a descriptor with the exact game source `id`, so the two IDs do different jobs. In the example, `Sword.Swing.Highlight` names the visual definition and `Sword.Swing` selects the Action that starts it. A binding uses either `event` or `state`, never both.

Pass the full catalog in the startup call. KRF validates the entire array before it connects to the transport and attaches the entries only when client startup succeeds. It never calls `create` during validation, so a malformed definition fails startup with a stable reason instead of failing later in play. See [PresentationDefinition](./api#presentationdefinition) and [Startup failures](./api#startup-failures).

## Pick an entry event

An event entry starts an instance each time a matching event reaches the client. `KRF.PresentationEvents` has a descriptor for every Action, Tag, Resource and Hint event an ActorView or the Hint runtime publishes, from `Action.Started` to `Hint.Received`. Each selector matches one source ID exactly. The [PresentationEvents](./api#presentationevents) table lists them with their source signals.

Narrow `ctx.entry` by its `source` to read the matching fields. The entry is a frozen record of the original observation: an Action entry carries the `ActionSnapshot` for that activation, a Tag entry its `tagId`, a Resource entry the `ResourceViewChange`, and a Hint entry its `hintId` and payload. A [state entry](#keep-an-aura-while-a-tag-is-active) has `source == "State"` instead. See [Entry event records](./api#entry-event-records).

Tags describe aggregate Actor state. A Hint creates an entry only if the client receives it. An Actor-targeted receipt requires the original ActorView to still be available. A world Hint has `ctx.actor == nil`. Hints can be lost and can arrive before or after related reliable state. See [Hints](../hints/guide).

KRF attaches to current and future ActorViews, including when a missing built-in domain appears in a later baseline. Baseline and recovery snapshots do not replay Action or Tag occurrences. `Resource.Changed` starts an instance only when `change.source == "Commit"`. Separate source callbacks do not guarantee a shared delivery order.

## Keep an aura while a Tag is active

A live `Tag.Added` entry only fires for clients that are watching when the Tag arrives. A player who joins while an enemy is already burning, or who streams that enemy in later, never sees the Added event, so an aura built on it would be missing for them. For a visual that should exist whenever a state is true, register a state entry instead. KRF reads the Actor's current replicated state, starts the instance when the state is present and retires it when the state goes away.

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local States = KRF.PresentationStates

local BurningAura: KRF.PresentationDefinition = {
	id = "Status.Burning.Aura",
	entry = { state = States.Tag.Active, id = "Burning" },
	create = function(ctx)
		local previous: Highlight? = nil

		local function detach()
			if previous ~= nil then
				previous:Destroy()
				previous = nil
			end
		end

		ctx:Own(detach)

		ctx:Watch(States.Actor.Model, function(model: Model?)
			detach()

			if not ctx:IsActive() or model == nil then
				return
			end

			local highlight = Instance.new("Highlight")
			highlight.Adornee = model
			highlight.Parent = model
			previous = highlight
		end)
	end,
}

return BurningAura
```

The aura moves with the Actor's Model through the Model Watch, and its one `Own` cleanup removes whatever Highlight is attached when the instance retires. You can still register a separate live `Tag.Added` definition for a one-off burst when the Tag first lands. Both run side by side, and the burst stays live-only.

`KRF.PresentationStates.Tag.Active` keeps one instance per definition, ActorView and Tag ID. A Tag is aggregate Actor state, so a stack or refresh keeps the same aura. `Action.Active` keeps one instance per activation instead, so two simultaneous activations of the same Action each get their own. You never write a sequence ID yourself. The other two descriptors, `Resource.Current` and `Actor.Model`, only work with [Watch](#watch-current-state). See [PresentationStates](./api#presentationstates).

An Action state entry works the same way for each active activation. This loop runs for as long as each `Sword.Charge` activation is active, including one that was already running when the player joined:

```luau
local ChargeLoop: KRF.PresentationDefinition = {
	id = "Sword.Charge.Loop",
	entry = { state = States.Action.Active, id = "Sword.Charge" },
	create = function(ctx)
		local entry = ctx.entry
		if entry.source ~= "State" or entry.kind ~= "Action" then
			return
		end

		local model = entry.actor:GetModel()
		local root = if model ~= nil then model.PrimaryPart else nil
		if root == nil then
			return
		end

		local light = Instance.new("PointLight")
		light.Parent = root
		ctx:Own(function()
			light:Destroy()
		end)
	end,
}
```

KRF retires each loop when its own activation ends or is interrupted, so the definition needs no `Action.Ended` listener. Another concurrent `Sword.Charge` activation gets a separate loop.

A state entry describes a current fact, not a past notification. Its `ctx.entry` has `source == "State"` and a `kind` of `"Tag"` or `"Action"`. A Tag state entry carries the `ActiveTagSnapshot` that was present when the instance started, and an Action state entry carries its activation's `ActionSnapshot`. See [State entry records](./api#state-entry-records).

An `ActionSnapshot` carries only the Action ID and sequence ID. KRF does not know an activation's phase, start time or elapsed playback, so a loop restored after a late join starts from the beginning of your visual. A Tag state entry's `ctx:On(Events.Tag.Removed, callback)` matches its own Tag ID, and an Action state entry's no-ID Action listeners and Action Watch match its own activation.

### How state instances start and stop

KRF reconciles each Actor's state when the ActorView first appears, when Presentation installs during `Client.Init` with views already present, after each committed change, and after a replacement baseline. If a Tag is removed and added again before KRF reconciles, it can see the Tag as continuously present and keep the existing aura. KRF does not invent the missed episode. Use a live `Tag.Added` entry if you need every occurrence.

When the state goes away, KRF retires the instance with normal owned cleanup, even if it never saw a Removed or Ended event. That retirement can happen before a scheduled `ctx:On(Events.Action.Ended, ...)` callback or a final `nil` from your own Watch, so put final cleanup in `ctx:Own`, not in those callbacks. Live event entries keep their own lifetime and never auto-retire this way. Retiring a visual never removes the Tag or ends the Action.

If your code calls `ctx:Finish()` while the state is still present, KRF treats that occurrence as handled and does not start it again. The same applies when `create` or one of its callbacks errors, or when the active-instance cap refuses it, so a broken aura cannot spin in a retry loop. A new instance starts only after KRF observes the state absent and then present again, or sees a different activation or a new ActorView.

`create` may yield. KRF checks that the state is still present right before calling it. If the state disappears while `create` is yielding, the instance retires and its cleanup runs. Check `ctx:IsActive()` after a yield, since KRF cannot cancel tasks you started yourself.

### Recovery and late joins

While an Actor is waiting for a replacement baseline after a replication fault, its ActorView stays available but its state may be stale. During that gap, which can last up to about 31 seconds, KRF keeps existing state instances running with the same identity and starts no new ones. Once the replacement baseline is installed, KRF reconciles against it: unchanged occurrences keep running, absent ones retire and newly present ones start. Existing visuals are not guaranteed to match the server during the gap. If the Actor is removed or its stream halts, all of its instances retire immediately. A new ActorView with the same Actor ID is a separate origin.

A Model change alone never retires a state instance, since the Tag or Action is still active. Roblox can also stream individual parts of a Model out while the Model itself stays bound. KRF does not detect that, so listen to the Roblox instances you attach to if your effect depends on specific parts.

## Own the visual's lifetime

Everything an instance owns hangs off its context. Register cleanup with `ctx:Own`, end the instance early with `ctx:Finish()`, and ask `ctx:IsActive()` whether it is still running. `ctx.actor` is the original ActorView, and a later view with the same Actor ID counts as a different origin. Finishing an instance retires only the visual, never the gameplay behind it. See [PresentationContext](./api#presentationcontext).

Cleanup runs in reverse registration order after the context becomes inactive. A failing or yielding cleanup is diagnosed, and remaining cleanups still run. Losing the Model alone leaves the instance active. Actor-less instances stay active until they finish or the runtime shuts down.

`create(ctx)` runs outside upstream Input and Networking callbacks and may yield. After a yield, check `IsActive()` before doing more asynchronous visual work. KRF owns the cleanup you register. Arrange cancellation for tasks you start separately and use `Own` for any visual objects you need to release. The return value of `create` is ignored.

Startup requires no assets. If an effect needs an asset, its author code can handle missing or slow assets locally. Constructor errors retire only that instance. KRF caps active instances per client and diagnoses refused occurrences when the cap is reached. See [Limits](./api#limits) and [Runtime diagnostics](./api#runtime-diagnostics).

## Observe events during an instance

Use `ctx:On` inside `create` to evolve an effect after its entry. All nine `PresentationEvents` descriptors work here. The instance owns the returned Connection, so you can disconnect it early or just let the instance release it.

With no ID, a listener follows the origin itself. An Action listener matches the instance's own activation, and a Tag, Resource or Hint listener matches the entry's own source ID. Pass an exact ID to listen to another source on the same ActorView, or a scope record such as `{ id = "Burning", actor = otherView }` to listen on a different Actor. Hints also accept `{ id = "Sword.Impact", scope = "Any" }` for receipts with any Actor association. A call that cannot be scoped raises a Presentation misuse error and never falls back to all Actors. See [On](./api#on) and [Misuse errors](./api#misuse-errors).

Annotate each callback parameter with its entry type, such as `KRF.TagEntryEvent`, for reliable field checking and autocomplete. The pinned Luau checker does not infer callback parameters from overloaded methods, as tracked in [Luau #3045](https://github.com/luau-lang/luau/issues/3045).

For example, a charging visual can change color on an Actor's Tag, react to a targeted Hint, and finish on its own Action's end or interruption:

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local Events = KRF.PresentationEvents

local Charge: KRF.PresentationDefinition = {
	id = "Sword.Charge.Visual",
	entry = { event = Events.Action.Started, id = "Sword.Charge" },
	create = function(ctx)
		local actor = ctx.actor
		local model = if actor ~= nil then actor:GetModel() else nil
		if actor == nil or model == nil then
			ctx:Finish()
			return
		end

		local highlight = Instance.new("Highlight")
		highlight.Adornee = model
		highlight.Parent = model
		ctx:Own(function()
			highlight:Destroy()
		end)

		ctx:On(Events.Tag.Added, "Charging", function(event: KRF.TagEntryEvent)
			highlight.FillColor = Color3.fromRGB(80, 160, 255)
		end)
		ctx:On(Events.Hint.Received, "Sword.Impact", function(event: KRF.HintEntryEvent)
			highlight.FillColor = Color3.fromRGB(255, 220, 80)
		end)
		ctx:On(Events.Action.Ended, function(event: KRF.ActionEntryEvent)
			ctx:Finish()
		end)
		ctx:On(Events.Action.Interrupted, function(event: KRF.ActionEntryEvent)
			ctx:Finish()
		end)

		local entry = ctx.entry
		if entry.source == "Action" and actor:GetActions():GetAction(entry.action.sequenceId) == nil then
			ctx:Finish()
		end
	end,
}

return Charge
```

The last check covers an Action that ended before `create` subscribed. A short Action can start and end in the same update, and `ctx:On` never replays that earlier end, so the example looks the activation up once its listeners are in place.

The no-ID Action listeners match the associated activation, so another concurrent `Sword.Charge` activation cannot finish this instance. Games do not supply a sequence ID. The runtime reads a private instance-owned association separately from the original entry; later predicted adoption can update that association without rewriting `ctx.entry` or replacing authored subscriptions. Prediction and adoption are not implemented by these subscriptions.

The Tag is aggregate Actor state, and a targeted Hint only identifies its Actor and Hint ID. Neither proves which Action activation produced it. Add correlation fields to your game Hint schema when overlapping effects need that distinction. Hints remain lossy and have no total ordering with reliable Actor state.

Connections install synchronously in `On`. Events from before registration are not replayed, including events missed while `create` yielded. To start from what is true right now, use a [state entry](#keep-an-aura-while-a-tag-is-active) or [`ctx:Watch`](#watch-current-state). Authored callbacks run after source publication returns and may yield without holding up that publication. Cross-source ordering and callback completion order are not guaranteed.

Finish, origin Actor retirement, runtime teardown and authored failures make the instance inactive and disconnect its subscriptions before owned cleanup runs. An equal-ID replacement view never inherits the old subscriptions.

Queued callbacks check connection and instance state immediately before invocation. A callback that has already started can continue after a yield, even if it was disconnected or the instance finished meanwhile. Check `ctx:IsActive()` before continuing asynchronous visual work, and own the resources you create. Callback errors retire the affected instance and diagnose its definition and event without interrupting other instances or core gameplay. This scheduling isolates publication paths; it does not limit the CPU that running game code can consume.

## Watch current state

`ctx:On` only hears about changes after you subscribe. When your effect needs to start from what is true now, use `ctx:Watch`. It calls back once with the current state, then again whenever that state meaningfully changes. Like `On`, it never synthesizes a past event.

Watch has four forms: a Tag or Resource by ID, the instance's own Action activation, and the Actor's Model. Each callback receives the current value, or `nil` while it is absent. See [Watch](./api#watch).

For example, a charge visual can brighten as its Actor's Mana fills:

```luau
ctx:Watch(KRF.PresentationStates.Resource.Current, "Mana", function(mana: KRF.ResourceSnapshot?)
	if mana ~= nil and ctx:IsActive() then
		highlight.FillTransparency = 1 - mana.current / mana.max
	end
end)
```

Watch always observes the original ActorView. It works on any instance that has one, including live event entries, but not on an Actor-less Hint instance. The Action form needs the instance's own activation, so it works only for Action entries. `On` and `Watch` share the instance's subscription slots.

Callbacks run after the change publishes and may yield. KRF reads the state again right before each callback, so several quick changes can collapse into one callback with the latest value. Watch is not an event log. A newer callback can start while an earlier one is still yielding, so check `ctx:IsActive()` before continuing asynchronous work. A callback error retires the instance.

KRF compares the replicated fields, not values that move with the clock. A Tag's `remainingDuration` and a regenerating Resource's `current` keep changing locally without a new callback. Read them again when you need the current value. Refreshing a Tag's expiry or changing a Resource's stored value does trigger a callback.

While an Actor is waiting for a replacement baseline, Tag, Action and Resource Watches pause. An existing Watch keeps the last value it delivered, and a Watch registered during the gap waits for the first callback until fresh state is installed. Both then catch up from that state. The Model Watch keeps following real Model changes throughout.

The instance owns each Watch. It disconnects on `:Disconnect()`, Finish, Actor retirement and runtime teardown. A state entry can retire as soon as its state disappears, so its own Watch may never deliver that final `nil`. Use `ctx:Own` for cleanup that must run.
