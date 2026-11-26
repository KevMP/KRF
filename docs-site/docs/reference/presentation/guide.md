---
title: Presentation
---

# Presentation

Register a client Presentation to start your own visual code when KRF delivers an Action, Tag, Resource or Hint event. Each matching event starts an independent instance for each definition. KRF finds the originating ActorView, scopes subscriptions to that view, and runs the cleanup you register.

## Highlight an Actor when an Action starts

Put this in the LocalScript that calls Client.Init. The server must already register a client-visible Action with ID `Sword.Swing` and publish the Actor that starts it. The example uses KRF for entry and lifetime and uses Roblox's native `Highlight` for the visual.

```luau
--!strict
local KRF = game:GetService("ReplicatedStorage").Packages.KRF
local Client = require(KRF.client)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Types = require(KRF.client.Presentation.types)

local swordHighlight: Types.PresentationDefinition = {
	id = "Sword.Swing.Highlight",
	entry = { event = Events.Action.Started, id = "Sword.Swing" },
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

local ok, failure = Client.Init({ presentations = { swordHighlight } })
assert(ok, if failure ~= nil then failure.system .. ": " .. failure.reason else "Client startup failed")
```

The effect can overlap with another swing, even on the same Actor. `Finish` retires just that instance. An Action end or interruption leaves existing instances active until they finish or their ActorView retires. If you want a visual to start on an Action end, register a definition for `Events.Action.Ended`.

## Register definitions

`Client.Init({ presentations = { ... } })` accepts a dense array of definition tables. An empty array and omitted configuration are valid. Each definition has a unique, nonempty string `id`, one `entry` binding and one `create(ctx)` function. The binding has two fields, an exported `PresentationEvents` descriptor and the exact, nonempty game source `id`. The two IDs serve different purposes. In the example, `Sword.Swing.Highlight` names the visual definition and `Sword.Swing` selects an Action.

Load the full catalog in the startup call. KRF validates the entire array before connecting to transport and attaches the entries only when client startup succeeds. Startup owns a copy of the IDs and binding and keeps the original function reference. It does not call `create` during validation. A malformed member fails startup under the `Presentation` system with a stable reason. See the [initialization API](../getting-started/initialization-api#clientinit).

## Pick an entry event

Require `KRF.client.Presentation.PresentationEvents` and use these frozen values in `entry.event`. Every selector matches one existing source ID exactly.

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

Cleanup runs in reverse registration order after the context becomes inactive. A failing or yielding cleanup is diagnosed, and remaining cleanups still run. Losing the Model alone leaves the instance active. Actor-less instances stay active until they finish or the runtime shuts down.

`create(ctx)` runs outside upstream Input and Networking callbacks and may yield. After a yield, check `IsActive()` before doing more asynchronous visual work. KRF owns the cleanup you register. Arrange cancellation for tasks you start separately and use `Own` for any visual objects you need to release. The return value of `create` is ignored.

Startup requires no assets. If an effect needs an asset, its author code can handle missing or slow assets locally. Constructor errors retire only that instance. KRF caps active instances per client and diagnoses refused occurrences when the cap is reached.
