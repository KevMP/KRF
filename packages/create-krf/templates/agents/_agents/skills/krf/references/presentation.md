# Presentation

Presentation is how a client shows gameplay: a cast flash, a hit spark, a burning aura, a sound. A Presentation definition starts your visual code when an Action, Tag, Resource or Hint event reaches the client, or while a Tag or Action is active, and KRF runs the cleanup the visual registers. It runs only on clients and never changes gameplay.

## Check whether it should be a Presentation

| The visual | Use |
| --- | --- |
| Plays once when something happens, such as a cast flash or a burst when a stun lands | A Presentation with an event entry |
| Lasts while a state is true, such as a burning aura or a channel loop, and must also appear for players who join later | A Presentation with a [state entry](#keep-a-visual-while-a-state-is-true) |
| Is the caster's own cast, which should start the moment they press | A predicted Presentation. See [Predict every Action players start](#predict-every-action-players-start) |
| Is UI that draws current values, such as a Mana bar or a nameplate | The ActorView directly. See [client-views.md](client-views.md) |
| Depends on something only the server knows, such as where a hit landed | A [Hint](hints.md), shown by a Presentation on `Hint.Received` |

## Generate it

```bash
npm run createPresentation -- --name FireballCast --id Fireball.Cast --event Action.Started --source-id Fireball --yes --json
```

`--source-id` is the exact Action, Tag, Resource or Hint ID that starts the visual, and `--id` names the visual itself. The generator writes the module under `src/client/Presentations` and wires the folder into `Startup.client.luau` on first use. It writes event entries only; for a state entry, change `entry` as shown [below](#keep-a-visual-while-a-state-is-true).

For every flag and how to read the result, see [generators.md](generators.md#createpresentation).

## Fill in create

KRF calls `create(ctx)` once for each matching event, so two overlapping casts get two instances:

```lua
local FireballCast: KRF.PresentationDefinition = {
	id = "Fireball.Cast",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Fireball" },
	create = function(ctx: KRF.PresentationContext): ()
		local actor: KRF.ActorView? = ctx.actor
		local model: Model? = if actor ~= nil then actor:GetModel() else nil

		if model == nil then
			ctx:Finish()
			return
		end

		local highlight: Highlight = Instance.new("Highlight")
		highlight.Adornee = model
		highlight.Parent = model

		ctx:Own(function(): ()
			highlight:Destroy()
		end)

		task.delay(0.4, function(): ()
			if ctx:IsActive() then
				ctx:Finish()
			end
		end)
	end,
}
```

- Register cleanup for everything the visual creates with `ctx:Own`. KRF runs it when the instance retires, in reverse order.
- An event instance lasts until you call `ctx:Finish()` or the Actor's view goes away. An Action ending doesn't finish it.
- `ctx.actor` is `nil` for a Hint with no Actor, and a view's Model can be `nil`. Finish when there's nothing to draw.
- `create` may yield. Check `ctx:IsActive()` after any yield before doing more work.
- A Presentation never changes gameplay, sends requests or decides anything. If an error retires it, only that visual stops.

## Keep a visual while a state is true

An event entry only fires for clients that are watching when the event happens. A player who joins while an enemy is already burning never sees `Tag.Added`. For a visual that should exist whenever a state is true, use a state entry:

```lua
local BurningAura: KRF.PresentationDefinition = {
	id = "Burning.Aura",
	entry = { state = KRF.PresentationStates.Tag.Active, id = "Burning" },
	create = function(ctx: KRF.PresentationContext): ()
		local highlight: Highlight? = nil

		local function detach(): ()
			if highlight ~= nil then
				highlight:Destroy()
				highlight = nil
			end
		end

		ctx:Own(detach)

		ctx:Watch(KRF.PresentationStates.Actor.Model, function(model: Model?): ()
			detach()

			if model ~= nil and ctx:IsActive() then
				local created: Highlight = Instance.new("Highlight")
				created.Adornee = model
				created.Parent = model
				highlight = created
			end
		end)
	end,
}
```

KRF starts the instance while the Tag is present, including for late joiners, and retires it when the Tag goes away. `Tag.Active` keeps one instance per Actor and Tag, so a refresh or a new stack keeps the same aura. `Action.Active` keeps one instance per running activation.

Put final cleanup in `ctx:Own`. KRF can retire a state instance before an `Action.Ended` listener or a final `nil` from a Watch runs.

## React while an instance runs

Inside `create`, `ctx:On(event, id?, callback)` listens for later events and `ctx:Watch(state, id?, callback)` reports current state now and again when it changes. With no ID, both follow the instance's own source: its own Action activation, Tag, Resource or Hint. The instance owns every connection.

`On` never replays events from before you subscribed, so use `Watch` or a state entry when the visual needs to start from what's true now. Annotate each callback's parameter with its type, such as `KRF.TagEntryEvent` or `KRF.ResourceSnapshot?`. The Luau checker doesn't infer them.

## Predict every Action players start

When a player presses Fireball, the request travels to the server, the server starts the Action, and only then does `Action.Started` come back. At 150 ms of ping the delay is obvious. A predicted Presentation starts the cast on the caster's own client as soon as the request is sent, and KRF reconciles it with the server's answer. Other players and NPCs still see the normal entry, and the same definition serves both.

Aim to predict every Action a player requests. Leave one unpredicted only when its visual must not appear before the server agrees, and say so when you report the work. Prediction needs three things.

First, keep the Action's start rules in a shared module, as [actions.md](actions.md#keep-start-rules-in-one-shared-module) describes, so the client checks the same Tags and costs the server does.

Second, pass that module as the Action's prediction policy. Add a folder that merges one module per Action, the same way `src/client/ActionInputPolicies` does. `src/client/ActionPredictionPolicies/init.luau` requires `ReplicatedStorage.Shared.MergeDescendants` as `mergeDescendants`:

```lua
local policies: KRF.ActionPredictionPolicies = mergeDescendants(script)

return policies
```

Then `src/client/ActionPredictionPolicies/Fireball.luau` requires `ReplicatedStorage.Shared.ActionRequirements.Fireball` as `FireballRequirements` and returns it as the policy:

```lua
local Fireball: KRF.ActionPredictionPolicies = {
	Fireball = FireballRequirements,
}

return Fireball
```

Require the folder in `Startup.client.luau` as `ActionPredictionPolicies` and pass it to `KRF.Client.Init`:

```lua
local started: boolean, failure: KRF.ClientStartupFailure? = KRF.Client.Init({
	actionRequestSchemas = ActionRequests,
	actionInputPolicies = ActionInputPolicies,
	actionPredictionPolicies = ActionPredictionPolicies,
	presentations = Presentations,
})
```

When the client can approximate a check the server makes in `onCanStart`, such as range to the target, add `canPredictStart` in the client module, next to the shared fields rather than in place of them. Here `CombatLimits` is a shared game module the server's `onCanStart` also reads:

```lua
local Fireball: KRF.ActionPredictionPolicies = {
	Fireball = {
		requiredTags = FireballRequirements.requiredTags,
		blockedTags = FireballRequirements.blockedTags,
		resourceRequirements = FireballRequirements.resourceRequirements,
		costs = FireballRequirements.costs,
		canPredictStart = function(ctx: KRF.ActionPredictionCheckContext): boolean?
			local model: Model? = ctx.actor:GetModel()
			local target: Vector3? = if ctx.parameters ~= nil then ctx.parameters.target else nil

			if model == nil or target == nil then
				return nil
			end

			return (target - model:GetPivot().Position).Magnitude <= CombatLimits.FireballRange
		end,
	},
}

return Fireball
```

Return `nil` when the client can't tell. Any number both checks use, such as that range, lives in one shared module that the server's `onCanStart` reads too, never in two constants.

Third, mark the cast definition `predict = true`. A predicted instance starts with `ctx.entry.source == "ActionPrediction"`, and the replicated `Action.Started` for the same activation doesn't start a second one:

```lua
local PredictedCast: KRF.PresentationDefinition = {
	id = "Fireball.Cast",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Fireball" },
	predict = true,
	create = function(ctx: KRF.PresentationContext): ()
		local actor: KRF.ActorView? = ctx.actor
		local model: Model? = if actor ~= nil then actor:GetModel() else nil

		if model == nil then
			ctx:Finish()
			return
		end

		local glow: Highlight = Instance.new("Highlight")
		glow.Adornee = model
		glow.Parent = model

		ctx:Own(function(): ()
			glow:Destroy()
		end)

		local accepted: boolean = ctx.entry.source ~= "ActionPrediction"

		if not accepted then
			ctx:Watch(KRF.PresentationStates.Action.LocalPrediction, function(status: KRF.LocalPredictionSnapshot): ()
				if status.startStatus == "Accepted" then
					accepted = true
				elseif status.startStatus == "Rejected" then
					ctx:Finish()
				end
			end)
		end

		ctx:Watch(KRF.PresentationStates.Action.Active, function(action: KRF.ActionSnapshot?): ()
			if action == nil and accepted then
				ctx:Finish()
			end
		end)
	end,
}
```

- End a predicted cast with `Watch(States.Action.Active)`, never with an `Action.Ended` listener alone. A short Action can end on the server before the client knows which activation is its own, and `On` never replays that end.
- Decide what a rejection does. KRF never finishes a rejected cast or rewinds an animation for you: fade it, cut it or let a short burst finish. A status of `"Unknown"` means the reply didn't arrive in time; give it a short timeout of your own.
- The estimate only covers what the policy declares. Grants, locks and the server's `onCanStart` stay on the server. Declare only `ClientVisible` Tags and Resources: the client can't see `ServerOnly` ones, and a cost with a `multiplierProperty` makes the estimate unknown, which skips the early visual.
- A blocked or unknown estimate starts nothing early. The request is still sent, and the definition starts normally from the replicated `Action.Started`.
- NPC casts and other players' casts aren't predicted, and use the same definition through the normal entry.

To show a predicted cast's hits on its target before the server's Hint arrives, give the Hint the attacker and activation fields from [hints.md](hints.md#let-the-attacker-show-the-hit-early), then call `ctx:PredictHint` from the predicted cast. The [Presentation guide](docs/presentation/guide.md#show-the-hit-before-the-server-confirms-it) walks through it.

## Exact APIs

- [Presentation guide](docs/presentation/guide.md): entries, ownership, `On`, `Watch`, prediction and predicted hits in depth.
- [Presentation API](docs/presentation/api.md): definition fields, entry records, every Watch form, prediction policies, `PredictHint` results, limits and startup failures.

## Related references

- [actions.md](actions.md) for the shared start rules prediction reads.
- [action-input.md](action-input.md) for the requests a prediction follows.
- [client-views.md](client-views.md) for UI that reads ActorViews directly.
- [hints.md](hints.md) for server-sent effects and predicted hits.
