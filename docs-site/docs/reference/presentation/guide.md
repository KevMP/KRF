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

The no-ID Action listeners match the associated activation, so another concurrent `Sword.Charge` activation cannot finish this instance. Games do not supply a sequence ID. The runtime keeps a private association for each instance, separate from `ctx.entry`. For a [predicted cast](#start-a-cast-before-the-server-answers), that association gains the server's sequence ID when the Start is accepted, and the same listeners start matching it without being registered again.

The Tag is aggregate Actor state, and a targeted Hint only identifies its Actor and Hint ID. Neither proves which Action activation produced it. Add correlation fields to your game Hint schema when overlapping effects need that distinction. Hints remain lossy and have no total ordering with reliable Actor state.

Connections install synchronously in `On`. Events from before registration are not replayed, including events missed while `create` yielded. To start from what is true right now, use a [state entry](#keep-an-aura-while-a-tag-is-active) or [`ctx:Watch`](#watch-current-state). Authored callbacks run after source publication returns and may yield without holding up that publication. Cross-source ordering and callback completion order are not guaranteed.

Finish, origin Actor retirement, runtime teardown and authored failures make the instance inactive and disconnect its subscriptions before owned cleanup runs. An equal-ID replacement view never inherits the old subscriptions.

Queued callbacks check connection and instance state immediately before invocation. A callback that has already started can continue after a yield, even if it was disconnected or the instance finished meanwhile. Check `ctx:IsActive()` before continuing asynchronous visual work, and own the resources you create. Callback errors retire the affected instance and diagnose its definition and event without interrupting other instances or core gameplay. This scheduling isolates publication paths; it does not limit the CPU that running game code can consume.

## Watch current state

`ctx:On` only hears about changes after you subscribe. When your effect needs to start from what is true now, use `ctx:Watch`. It calls back once with the current state, then again whenever that state meaningfully changes. Like `On`, it never synthesizes a past event.

Watch has five forms: a Tag or Resource by ID, the instance's own Action activation, the Actor's Model and, for a [predicted cast](#watch-the-requests-local-status), its local request status. Each callback receives the current value, or `nil` while it is absent. See [Watch](./api#watch).

For example, a charge visual can brighten as its Actor's Mana fills:

```luau
ctx:Watch(KRF.PresentationStates.Resource.Current, "Mana", function(mana: KRF.ResourceSnapshot?)
	if mana ~= nil and ctx:IsActive() then
		highlight.FillTransparency = 1 - mana.current / mana.max
	end
end)
```

Watch always observes the original ActorView. It works on any instance that has one, including live event entries, but not on an Actor-less Hint instance. The Action form needs the instance's own activation, so it works only for Action entries and predicted casts. `On` and `Watch` share the instance's subscription slots.

Callbacks run after the change publishes and may yield. KRF reads the state again right before each callback, so several quick changes can collapse into one callback with the latest value. Watch is not an event log. A newer callback can start while an earlier one is still yielding, so check `ctx:IsActive()` before continuing asynchronous work. A callback error retires the instance.

KRF compares the replicated fields, not values that move with the clock. A Tag's `remainingDuration` and a regenerating Resource's `current` keep changing locally without a new callback. Read them again when you need the current value. Refreshing a Tag's expiry or changing a Resource's stored value does trigger a callback.

While an Actor is waiting for a replacement baseline, Tag, Action and Resource Watches pause. An existing Watch keeps the last value it delivered, and a Watch registered during the gap waits for the first callback until fresh state is installed. Both then catch up from that state. The Model Watch keeps following real Model changes throughout.

The instance owns each Watch. It disconnects on `:Disconnect()`, Finish, Actor retirement and runtime teardown. A state entry can retire as soon as its state disappears, so its own Watch may never deliver that final `nil`. Use `ctx:Own` for cleanup that must run.

## Start a cast before the server answers

A player presses Fireball and waits a full round trip before anything happens: the request travels to the server, the server starts the Action, and only then does `Action.Started` come back. At 150 ms of ping that wait is obvious. Prediction lets the caster's own client start the real Presentation instance as soon as the request leaves, then reconcile that instance with the server's answer. It is optional and client-only. Without it nothing changes, and other players and NPCs always get the ordinary authoritative entry.

Prediction needs two things. A policy for the Action says which checks the client can make itself, and a definition opts in with `predict = true`:

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)
local FireballRequirements = require(ReplicatedStorage.Shared.FireballRequirements)

local ok, failure = KRF.Client.Init({
	actionRequestSchemas = require(ReplicatedStorage.Shared.ActionRequestSchemas),
	actionPredictionPolicies = {
		Fireball = {
			requiredTags = FireballRequirements.requiredTags,
			blockedTags = FireballRequirements.blockedTags,
			resourceRequirements = FireballRequirements.resourceRequirements,
			costs = FireballRequirements.costs,
			canPredictStart = function(ctx: KRF.ActionPredictionCheckContext): boolean?
				local model = ctx.actor:GetModel()
				local target = if ctx.parameters ~= nil then ctx.parameters.target else nil

				if model == nil or target == nil then
					return nil
				end

				return (target - model:GetPivot().Position).Magnitude <= 60
			end,
		},
	},
	presentations = Presentations,
})
```

The policy's Action ID must be in your `actionRequestSchemas`, because only a request the client can send can be predicted. The tables come from an ordinary game ModuleScript that the server's Fireball factory also uses for its `ActionDefinition`, so both sides read the same numbers:

```luau
--!strict
-- ReplicatedStorage/Shared/FireballRequirements.luau
return {
	requiredTags = { "Status.Grounded" },
	blockedTags = { "Status.Stunned" },
	resourceRequirements = { Mana = { min = 30 } },
	costs = { Mana = 20 },
}
```

Sharing the module is a convenience, not a requirement. A client policy can declare fewer checks than the server, or approximate one in `canPredictStart`. KRF copies the policy at startup, so changing the shared tables later does not change the installed policy.

### What the client checks

When the client's Action request runtime admits a Fireball Start and sends it, KRF evaluates the policy once, right after the packet leaves. It checks only what you declared, against the original ActorView that made the request. Tags are read with `TagsView:HasTag`. Resource requirements and fixed or percentage costs are read with `ResourcesView:GetResource`, using the same inclusive bounds as the server, and cooldown or charge Resources work like any other Resource. The client never spends anything. Last, `canPredictStart(ctx)` receives the original ActorView, the Action ID, the request's `originalStartKey` and its `parameters`, decoded from the exact bytes that were sent.

The result is one of three estimates. If every declared check passes, the Start is likely allowed and the cast begins now. If a declared check fails, it is likely blocked. If a check needs data the client does not have, the estimate is unknown. That happens while the ActorView waits for a replacement baseline, when a declared Resource is not replicated, when a cost names a `multiplierProperty` (the client has no Property values to resolve it), and when the callback returns `nil`, errors, yields, returns something other than a boolean or runs longer than 5 ms. Blocked and unknown both skip the early visual. The request is sent either way: prediction never decides whether a request goes out, and the server alone decides whether it runs.

These are estimates of your declared checks, not of the server's whole decision. Grants, locks, the server's `onCanStart` and anything else you did not declare stay on the server, and a passing policy says nothing about them. Declare only Tags and Resources the client can see. `HasTag` returns `false` both for an absent Tag and for a `ServerOnly` Tag the client never receives, so a hidden blocked Tag can never block a prediction, and KRF cannot detect that mistake for you.

### One instance, from press to server answer

A predicted definition starts the same kind of instance as any other, with `create(ctx)` called once. Its `ctx.entry` has `source == "ActionPrediction"` and `event == "RequestAdmitted"`, plus `actor`, `actionId`, `originalStartKey` and its own copy of the decoded `parameters`. Two predicted definitions for one Action each get their own instance and their own parameter table, and the policy still runs only once.

```luau
local Cast: KRF.PresentationDefinition = {
	id = "Fireball.Cast",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Fireball" },
	predict = true,
	create = function(ctx)
		local model = if ctx.actor ~= nil then ctx.actor:GetModel() else nil
		if model == nil then
			ctx:Finish()
			return
		end

		local glow = Instance.new("Highlight")
		glow.Adornee = model
		glow.Parent = model
		ctx:Own(function()
			glow:Destroy()
		end)

		local predicted = ctx.entry.source == "ActionPrediction"
		local accepted = not predicted

		local function fade()
			glow.FillColor = Color3.fromRGB(120, 120, 120)
			task.delay(0.2, function()
				ctx:Finish()
			end)
		end

		if predicted then
			ctx:Watch(KRF.PresentationStates.Action.LocalPrediction, function(status: KRF.LocalPredictionSnapshot)
				if status.startStatus == "Accepted" then
					accepted = true
				elseif status.startStatus == "Rejected" then
					fade()
				elseif status.startStatus == "Unknown" then
					task.delay(1, function()
						if not accepted and ctx:IsActive() then
							fade()
						end
					end)
				end
			end)
		end

		ctx:Watch(KRF.PresentationStates.Action.Active, function(action: KRF.ActionSnapshot?)
			if action == nil and accepted then
				ctx:Finish()
			end
		end)
	end,
}
```

When the server accepts the Start, KRF attaches the real sequence ID to this instance. It does not call `create` again, and when the replicated `Action.Started` for that exact activation arrives, KRF does not start a second instance of this definition. `Watch(States.Action.Active)` and no-ID Action listeners such as `ctx:On(Events.Action.Ended, ...)` begin matching that activation. Until then they match nothing, and they never widen to other Fireballs on the same Actor. `ctx.entry` itself never changes. Definitions without `predict` are unaffected and still start from the replicated `Action.Started`.

The example ends the cast with the Action.Active Watch rather than an `Action.Ended` listener, and that choice matters here. A short Fireball can start and end on the server before its reply reaches the client. The replicated Ended then arrives before this instance knows its sequence ID, and `ctx:On` never replays it. The Watch reports `nil` until the Start is accepted. After that it reports the activation once its replicated Start has arrived, and `nil` again when it ends, so a cast that already ended still finishes and an accept that arrives a moment before the replicated Start does not end the cast early. The example also fades a cast whose reply is `"Unknown"` and stays unanswered for a second, since that request may never resolve.

If the estimate was blocked or unknown, no early instance exists, and the predicted definition starts normally from the replicated `Action.Started`, like any other definition. Branch on `ctx.entry.source` when the two paths need different code, as the example does for its rejection fade.

### Watch the request's local status

`ctx:Watch(States.Action.LocalPrediction, callback)` works only on an instance created by a prediction. Its first callback carries everything already known, including facts that arrived before `create` ran, because a quick press and release can both happen before the instance exists. Later callbacks can collapse several changes into one.

The snapshot's `startStatus` is `"Admitted"` until the server answers, then `"Accepted"` with a `sequenceId`, or `"Rejected"` with a `startReason`. `"Unknown"` means the reply did not arrive in time. The server may still have run the Action, and a late `"Accepted"` or `"Rejected"` can follow. `inputTransitions` lists the original press's local input decisions in order, such as `"GenuineRelease"` or `"InvalidatedKeep"`. `lastStop` and `lastInterrupt` track the latest Stop and Interrupt requests, each with its own `requestKey` and status.

None of these statuses means the Action has ended. An accepted Start proves the server started it, not that it is still running, and an accepted Stop is a request the server took, not an end. Use `Watch(States.Action.Active)` or `ctx:On(Events.Action.Ended, ...)` for the server's actual Action state. KRF never finishes a rejected cast for you or rewinds an animation: you choose whether to fade it, cut it or let a short burst finish.

### When the replicated Start arrives first

Usually the server's reply reaches the client before or with the replicated `Action.Started`, and KRF matches them exactly. The replicated Start carries no request key, though. If it arrives first while one of your casts of the same Action on the same ActorView is still waiting for its reply, KRF cannot yet tell whether the two are the same activation. It holds back the predicted definitions' entry for that one Start for at most 0.5 seconds. A matching reply adopts it, and a reply proving it is a different activation, or a rejection, releases it at once. Nothing else waits: networking, input and definitions without `predict` carry on as usual.

If nothing settles it within the window, for example because the reply came back `"Unknown"`, KRF starts the authoritative instance anyway, and you can see one extra copy of the visual. That is deliberate. KRF never merges two activations it cannot prove are the same, and never hides a genuine Start indefinitely. A reply that arrives later still updates the predicted instance's status, but cannot undo a visual that already started. A held Start can also begin after its activation has already ended, so give predicted definitions an Action.Active Watch, as the example does, rather than relying on a live `Action.Ended` alone.

A request whose reply never arrives stops counting as a candidate 20 seconds after it was sent, which is when the client gives up on a late reply. After that, its predicted instance stays active until you finish it, but it no longer holds back other Starts.

An instance that finishes before its replicated Start arrives leaves a small correlation record behind, so that Start is still recognized and not replayed. Those records, pending requests and held entries all have fixed limits, listed in [Limits](./api#limits). When a limit is reached KRF warns and falls back to ordinary authoritative creation.

### Show the hit before the server confirms it

The cast now starts the moment the player presses, but the spark where the Fireball lands still waits. Your server decides what the Fireball hit and tells clients with a Hint, and that Hint is a full round trip behind the cast on the caster's screen. The caster's client already knows when its own Fireball should land and what it aimed at, so it can show the impact now and skip the server's copy when it arrives. Other players still see the impact from the server's Hint, as before.

Start on the server. The impact Hint needs to say which activation caused it, so the client can match it to its own cast. Add the attacker's Actor ID and the activation's `sequenceId` to the Hint's payload, and send it from the Action once your hit check succeeds:

```luau
-- In Server.Init's hints:
{
	id = "Fireball.Impact",
	direction = "ServerToClient",
	target = "Actor",
	mode = "Pulse",
	payload = KRF.Schema.Struct({
		attackerId = KRF.Schema.String(64),
		sequenceId = KRF.Schema.U32,
	}),
}

-- In the Fireball Action, where the server's hit check succeeds:
for _, player in Players:GetPlayers() do
	KRF.ServerHintRuntime.SendTo(player, "Fireball.Impact", target, {
		attackerId = ctx.actor:GetId(),
		sequenceId = ctx.sequenceId,
	})
end
```

On the client, tell KRF which payload fields carry that identity, and mark the impact definition `predict = true`:

```luau
KRF.Client.Init({
	actionRequestSchemas = require(ReplicatedStorage.Shared.ActionRequestSchemas),
	actionPredictionPolicies = { Fireball = FireballPolicy },
	hintPredictionPolicies = {
		["Fireball.Impact"] = { actorIdField = "attackerId", sequenceIdField = "sequenceId" },
	},
	presentations = Presentations,
})

local Spark: KRF.PresentationDefinition = {
	id = "Fireball.Spark",
	entry = { event = KRF.PresentationEvents.Hint.Received, id = "Fireball.Impact" },
	predict = true,
	create = function(ctx)
		local model = if ctx.actor ~= nil then ctx.actor:GetModel() else nil
		if model == nil then
			ctx:Finish()
			return
		end

		local burst = ReplicatedStorage.Effects.Spark:Clone()
		burst.Parent = model.PrimaryPart
		burst:Emit(20)
		ctx:Own(function()
			burst:Destroy()
		end)

		task.delay(0.5, function()
			ctx:Finish()
		end)
	end,
}
```

Last, the predicted cast predicts its own hit. When the Fireball would land on the client, it calls `ctx:PredictHint` with the Hint ID and the target it hit:

```luau
-- Inside Fireball.Cast's create, after the cast starts:
task.delay(FLIGHT_SECONDS, function()
	local target = Aim.FindTarget(ctx.entry)
	if target ~= nil and ctx:IsActive() then
		ctx:PredictHint("Fireball.Impact", target)
	end
end)
```

`Spark.create` runs right away with `ctx.actor` set to the target and `ctx.entry.source == "HintPrediction"`. When the server's `Fireball.Impact` arrives from the same activation for the same target, Spark skips it. Definitions for that Hint without `predict`, such as damage numbers you only want from the server, still run from it. A cast that hits the same target several times can call `PredictHint` once per hit, and each server Hint consumes one predicted hit in order.

`PredictHint` only works on an instance created by a prediction. On the authoritative Fireball instances, including other players' casts, it returns `false, "PredictionUnavailable"` and changes nothing, so the same `create` works for both: those instances simply get the spark from the server's Hint. The [PredictHint reference](./api#predicthint) lists every result.

The server stays in charge of the hit. Nothing here tells the server what the client thinks it hit, and a predicted hit is a guess about one cosmetic Hint:

- If the server rejects the cast, the predicted spark has already played. Watch `States.Action.LocalPrediction` on the spark instance, the same status its cast sees, if you want to cut it short.
- If the server decides the Fireball missed, it never sends the Hint, and Hints can be lost anyway, so nothing tells the client. The predicted hit stops waiting after 3 seconds. Keep predicted hits to short bursts, such as sparks, flashes, sounds and flinches, and leave damage numbers, knockback and ragdolls to the server's Hint.
- If the server's Hint arrives before the cast's reply, KRF holds it for at most 0.5 seconds while it matches them, the same way it holds an early replicated Start.
- If the server's Hint arrives before your `PredictHint` call, the Hint plays normally. When the call comes within 3 seconds and KRF already knows the Hint came from this cast, it returns `false, "HintAlreadyReceived"` without starting a second spark. If the call comes before the cast's reply proves that, the spark can play twice.
