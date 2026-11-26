---
title: Presentation
---

# Presentation

Register a client Presentation to start your own visual code when KRF delivers an Action, Tag, Resource or Hint event. Each matching event starts an independent instance for each definition. KRF finds the originating ActorView, scopes subscriptions to that view, and runs the cleanup you register.

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

`KRF.Client.Init({ presentations = { ... } })` accepts a dense array of definition tables. An empty array and omitted configuration are valid. Each definition has a unique, nonempty string `id`, one `entry` binding and one `create(ctx)` function. The binding has two fields, an exported `PresentationEvents` descriptor and the exact, nonempty game source `id`. The two IDs serve different purposes. In the example, `Sword.Swing.Highlight` names the visual definition and `Sword.Swing` selects an Action.

Load the full catalog in the startup call. KRF validates the entire array before connecting to transport and attaches the entries only when client startup succeeds. Startup owns a copy of the IDs and binding and keeps the original function reference. It does not call `create` during validation. A malformed member fails startup under the `Presentation` system with a stable reason. See the [initialization API](../getting-started/initialization-api#clientinit).

## Pick an entry event

Use these frozen values from `KRF.PresentationEvents` in `entry.event`. Every selector matches one existing source ID exactly.

| Descriptor | Source signal | Select by |
| --- | --- | --- |
| `Action.Started` | `ActorView:GetActions().OnActionStarted` | Action ID |
| `Action.Ended` | `ActorView:GetActions().OnActionEnded` | Action ID |
| `Action.Interrupted` | `ActorView:GetActions().OnActionInterrupted` | Action ID |
| `Tag.Added` | `ActorView:GetTags().OnTagAdded` | Tag ID |
| `Tag.Refreshed` | `ActorView:GetTags().OnTagRefreshed` | Tag ID |
| `Tag.Removed` | `ActorView:GetTags().OnTagRemoved` | Tag ID |
| `Tag.Expired` | `ActorView:GetTags().OnTagExpired` | Tag ID |
| `Resource.Changed` | `ActorView:GetResources().OnResourceChanged` | Resource ID |
| `Hint.Received` | `HintRuntime.OnHintReceived` | Hint ID |

Narrow `ctx.entry` by its `source` to read the matching type. The entry is a frozen record of the original observation.

| `source` | `event` | Entry fields |
| --- | --- | --- |
| `Action` | `Started`, `Ended`, `Interrupted` | `actor: ActorView`, `action: ActionSnapshot` with `actionId` and `sequenceId` |
| `Tag` | `Added`, `Refreshed`, `Removed`, `Expired` | `actor: ActorView`, `tagId: string` |
| `Resource` | `Changed` | `actor: ActorView`, `change: ResourceViewChange` with `resourceId`, `previous`, `current` and `source` |
| `Hint` | `Received` | `actor: ActorView?`, `hintId: string`, `payload: any?` from the declared Hint |

Action observations carry the activation's sequence ID. Tags describe aggregate Actor state. Hint payloads keep the existing Hint contract and can contain game-defined data. A Hint creates an entry only if the client receives it. An Actor-targeted receipt requires the original ActorView to still be available. A world Hint has `ctx.actor == nil`. Hints can be lost and can arrive before or after related reliable state. See [Hints](../hints/guide).

KRF attaches to current and future ActorViews, including when a missing built-in domain appears in a later baseline. Baseline and recovery snapshots do not replay Action or Tag occurrences. `Resource.Changed` starts an instance only when `change.source == "Commit"`. Separate source callbacks do not guarantee a shared delivery order.

## Own the visual's lifetime

| Context member | Behavior |
| --- | --- |
| `ctx.entry` | The immutable initial observation |
| `ctx.actor` | The original ActorView, if present. A later view with the same ID is a different origin. |
| `ctx:Own(cleanup)` | Register a non-yielding cleanup function. Registration after retirement invokes the cleanup immediately. |
| `ctx:Finish()` | Retire this instance once and schedule its registered cleanup. The underlying gameplay is unaffected. |
| `ctx:IsActive()` | True from acceptance until explicit finish, Actor retirement or runtime shutdown |
| `ctx:On(event, [id or scope,] callback)` | Subscribe to future observations; this instance owns the returned Connection. |

Cleanup runs in reverse registration order after the context becomes inactive. A failing or yielding cleanup is diagnosed, and remaining cleanups still run. Losing the Model alone leaves the instance active. Actor-less instances stay active until they finish or the runtime shuts down.

`create(ctx)` runs outside upstream Input and Networking callbacks and may yield. After a yield, check `IsActive()` before doing more asynchronous visual work. KRF owns the cleanup you register. Arrange cancellation for tasks you start separately and use `Own` for any visual objects you need to release. The return value of `create` is ignored.

Startup requires no assets. If an effect needs an asset, its author code can handle missing or slow assets locally. Constructor errors retire only that instance. KRF caps active instances per client and diagnoses refused occurrences when the cap is reached.

## Observe events during an instance

Use `ctx:On` inside `create` to evolve an effect after its entry. All nine `PresentationEvents` descriptors work here. The returned KRF Connection supports idempotent `:Disconnect()`. You can disconnect early, or drop the handle and let the instance release it automatically. There is no need to register it with `Own`.

| Form | Matching scope |
| --- | --- |
| `ctx:On(event, callback)` | Original source identity. Action listeners use the instance's associated activation; Tag, Resource and Hint listeners require an entry from the same family. |
| `ctx:On(event, "ExactId", callback)` | Exact source ID on the original ActorView. Action IDs match across activations. An Actor-less Hint origin matches Actor-less Hints. |
| `ctx:On(event, { id = "ExactId", actor = otherView }, callback)` | Exact source ID on that ActorView identity. A different Actor never inherits the original activation. |
| `ctx:On(Events.Hint.Received, { id = "ExactId", scope = "Any" }, callback)` | Matching Hints with any Actor association, including Actor-less receipts. Only Hints support this scope. |

IDs are nonempty strings. Scope records require an explicit ID. An Actor-based listener needs an available original Actor or an explicit ActorView override. Missing origin identity and malformed calls raise a Presentation misuse error; they never select all Actors. `On` on an inactive context returns an inert Connection without validating or subscribing. Each instance allows up to 64 simultaneous subscriptions; disconnecting frees a slot. Exceeding the limit raises a Presentation error without evicting existing listeners.

Each descriptor accepts a source-specific callback: `KRF.ActionEntryEvent`, `KRF.TagEntryEvent`, `KRF.ResourceEntryEvent` or `KRF.HintEntryEvent`, with the fields shown above. Annotate the callback parameter for reliable field checking and autocomplete. The pinned Luau checker does not infer callback parameters from overloaded methods, as tracked in [Luau #3045](https://github.com/luau-lang/luau/issues/3045). Incompatible annotated callbacks are rejected. The outer record is frozen. Hint payloads retain their existing game-authored semantics. Resource follow-ups preserve `change.source`, including real `Baseline` notifications, while Resource entries still admit only `Commit` changes.

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

Connections install synchronously in `On`. Events from before registration are not replayed, including events missed while `create` yielded. This API does not reconstruct current effects from snapshots; state-aware recovery is separate work. Authored callbacks run after source publication returns and may yield without holding up that publication. Cross-source ordering and callback completion order are not guaranteed.

Finish, origin Actor retirement, runtime teardown and authored failures make the instance inactive and disconnect its subscriptions before owned cleanup runs. Retiring an explicitly observed other Actor disconnects only listeners scoped to that view. Losing a Model alone does not retire an Actor. An equal-ID replacement view never inherits the old subscriptions.

Queued callbacks check connection and instance state immediately before invocation. A callback that has already started can continue after a yield, even if it was disconnected or the instance finished meanwhile. Check `ctx:IsActive()` before continuing asynchronous visual work, and own the resources you create. Callback errors retire the affected instance and diagnose its definition and event without interrupting other instances or core gameplay. This scheduling isolates publication paths; it does not limit the CPU that running game code can consume.
