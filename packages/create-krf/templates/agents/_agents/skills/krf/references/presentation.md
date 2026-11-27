# Presentation

Presentation is how a client shows gameplay: a cast flash, a hit spark, a burning aura, a sound, a character animation, and the content those need fetched early. A Presentation definition starts your visual code when an Action, Tag, Resource or Hint event reaches the client, or while a Tag or Action is active, and KRF runs the cleanup the visual registers. It runs only on clients and never changes gameplay.

## Check whether it should be a Presentation

| The visual | Use |
| --- | --- |
| Plays once when something happens, such as a cast flash or a burst when a stun lands | A Presentation with an event entry |
| Lasts while a state is true, such as a burning aura or a channel loop, and must also appear for players who join later | A Presentation with a [state entry](#keep-a-visual-while-a-state-is-true) |
| Is the caster's own cast, which should start the moment they press | A predicted Presentation. See [Predict every Action players start](#predict-every-action-players-start) |
| Plays a character animation, on its own or as part of another visual | `KRF.Animations.Play`, inside a Presentation or any LocalScript. See [Play animations with KRF.Animations](#play-animations-with-krfanimations) |
| Should look complete on its first use, so its animation, sound or textures should download beforehand | `KRF.Assets.Preload` when the player reaches the encounter. See [Fetch assets early with KRF.Assets](#fetch-assets-early-with-krfassets) |
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

## Play animations with KRF.Animations

`KRF.Animations.Play(model, animationId, options?)` plays an animation on any rig Model: a player character, an NPC or a dummy. It finds the Model's Humanoid or AnimationController and its Animator, loads the animation once, and reuses that track on every later call. It works inside a Presentation or in any LocalScript, with or without `KRF.Client.Init`. Use it instead of calling `LoadAnimation` yourself:

```lua
local FireballCastAnimation: KRF.PresentationDefinition = {
	id = "Fireball.Cast.Animation",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Fireball" },
	create = function(ctx: KRF.PresentationContext): ()
		local actor: KRF.ActorView? = ctx.actor
		local model: Model? = if actor ~= nil then actor:GetModel() else nil

		if model == nil then
			ctx:Finish()
			return
		end

		local playback: KRF.AnimationPlayback?, reason: string? =
			KRF.Animations.Play(model, "rbxassetid://123456", { priority = Enum.AnimationPriority.Action })

		if playback == nil then
			warn(reason)
			ctx:Finish()
			return
		end

		ctx:Own(function(): ()
			playback:Destroy()
		end)

		ctx:Watch(KRF.PresentationStates.Action.Active, function(action: KRF.ActionSnapshot?): ()
			if action == nil then
				ctx:Finish()
			end
		end)
	end,
}
```

- Register `playback:Destroy()` with `ctx:Own`. The animation ending by itself doesn't finish the instance, so finish it from the state or event that ends the visual.
- There is one cached track per Animator and animation ID. Each `Play` restarts it from the beginning and makes every earlier handle inert, so an older cast's cleanup can't stop a newer cast. For two copies of one animation on the same rig at once, call `Animator:LoadAnimation` for the second.
- Every `Play` applies its options fresh. Left-out fields take the defaults: `fadeTime = 0.1`, `weight = 1`, `speed = 1`, `priority = Enum.AnimationPriority.Action`, `looped = false`. Pass `looped = true` for a loop.
- The Model must be in Workspace, or in a WorldModel for a ViewportFrame preview, and have a direct child Humanoid or AnimationController. `Play` creates only a missing Animator, never a rig, and returns `nil` and a reason when it can't start. A returned handle doesn't prove the asset animates: an unusable or unloaded asset, or a rig with no joints, plays without moving anything.
- Use `playback:GetTrack()` only to read the track or connect `GetMarkerReachedSignal`. Calling `Play` or `Stop` on the track, or setting its properties, bypasses the handle.
- KRF picks no assets and adds no replication. Roblox replicates a client's animations on its own character only. Gameplay, such as hit timing, never depends on an animation or its markers.
- Sounds, particles, beams and camera effects are plain Roblox code released with `ctx:Own`. KRF has no helpers for them; don't invent any.

See [Play a character animation](docs/presentation/guide.md#play-a-character-animation) and the [Animations API](docs/presentation/api.md#animations) for every option, failure reason and limit.

## Fetch assets early with KRF.Assets

The first cast of an effect can look bare while Roblox is still downloading its animation, sound or textures. `KRF.Assets.Preload(items, onComplete?)` asks Roblox's `ContentProvider:PreloadAsync` to fetch content the game picks, at a moment the game picks, such as entering an arena or equipping a staff. It works in any LocalScript or Presentation, with or without `KRF.Client.Init`, and nothing ever waits for it:

```lua
local function prepareFireball(effects: Folder): ()
	local accepted: boolean, reason: string? = KRF.Assets.Preload({
		{ kind = "Animation", assetId = "rbxassetid://123456" },
		{ kind = "Sound", assetId = "rbxassetid://654321" },
		effects,
	}, function(report: KRF.PreloadReport): ()
		if report.error ~= nil then
			warn("Fireball preload stopped:", report.error)
		end

		for contentId: string, status: Enum.AssetFetchStatus in report.statuses do
			if status ~= Enum.AssetFetchStatus.Success then
				warn("Fireball content not fetched:", contentId, status.Name)
			end
		end
	end)

	if not accepted then
		warn("Fireball preload refused:", reason)
	end
end
```

- Call it explicitly for a specific encounter, area or item. Never preload all of Workspace, ReplicatedStorage or every Presentation, and never preload every frame. A selection over 2048 Instances fetches nothing and reports `PreloadDescendantLimit`.
- Pass Instances the effect uses, or a Folder or Model of effect templates. KRF walks each item and its descendants and passes only content classes: Animation, Sound, ParticleEmitter, Beam, Trail, Decal, Texture, MeshPart, SpecialMesh, ImageLabel, ImageButton and Sky. It never clones, moves, changes or destroys them, so keep them in place until `onComplete` runs. Pass a Folder itself rather than its `GetChildren()`, which can exceed the 64-item limit.
- Use a `{ kind = "Animation" | "Sound", assetId = "rbxassetid://..." }` descriptor when there is only an ID. Never pass a bare ID string; it is refused. For a texture, put an Instance that uses it in the templates Folder.
- `true` only means the request was accepted. Never make an Action, a Presentation, input or `KRF.Client.Init` wait for `onComplete`: it can arrive late, and never arrives if Roblox's call never returns. Visual code must still work when an asset hasn't loaded.
- Read `report.statuses` per content ID. `Success` means Roblox fetched it then, not that it stays in memory or is the right asset type. `Failure` and `TimedOut` are separate, `None` and `Loading` count as not fetched, and an empty map doesn't mean anything loaded. `report.error` is set only when the request stopped early, never for an ordinary failed fetch. KRF never retries.
- At most 8 requests run at once. A ninth returns `false, "PreloadBusy"` and is not queued; try again later or skip it.
- SurfaceAppearance and MaterialVariant can't be preloaded and are skipped. Preloading an Animation doesn't load a track; `KRF.Animations.Play` still does that. KRF has no effect pool or pre-spawning; don't invent one.

See [Fetch an encounter's assets early](docs/presentation/guide.md#fetch-an-encounters-assets-early) and the [Assets API](docs/presentation/api.md#assets) for every item form, status, refusal reason and limit.

## Predict every Action players start

When a player presses Fireball, the request travels to the server, the server starts the Action, and only then does `Action.Started` come back. At 150 ms of ping the delay is obvious. A predicted Presentation starts the cast on the caster's own client as soon as the request is sent, and KRF reconciles it with the server's answer. Other players and NPCs still see the normal entry, and the same definition serves both.

Aim to predict every Action a player requests. Leave one unpredicted only when its visual must not appear before the server agrees, and say so when you report the work. The generators set up everything except the visual:

| Generator | Writes |
| --- | --- |
| `createAction --requestable` | The Action's start rules in `src/shared/ActionRequirements/<Name>.luau`, read by the server definition. See [actions.md](actions.md#keep-start-rules-in-one-shared-module) |
| `createAction --requestable` | Its prediction policy in `src/client/ActionPredictionPolicies/<Name>.luau`, which passes that same module to the client. The first one also adds the folder's loader and passes it to `KRF.Client.Init` as `actionPredictionPolicies` |
| `createPresentation` with `Action.Started` | `predict = true`, when the source Action has a prediction policy. Pass `--no-predict` only for a visual that must wait for the server |

So the client checks the same Tags and costs the server does, without a second copy. Never write a prediction policy's Tags or costs by hand.

When the client can approximate a check the server makes in `onCanStart`, such as range to the target, add `canPredictStart` to the generated policy module, next to the shared fields rather than in place of them. Here `FireballRequirements` is the module the generated policy already requires, and `CombatLimits` is a shared game module the server's `onCanStart` also reads:

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

Then fill in the generated cast definition. A predicted instance starts with `ctx.entry.source == "ActionPrediction"`, and the replicated `Action.Started` for the same activation doesn't start a second one:

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

- [Presentation guide](docs/presentation/guide.md): entries, ownership, animations, preloading, `On`, `Watch`, prediction and predicted hits in depth.
- [Presentation API](docs/presentation/api.md): definition fields, entry records, every Watch form, prediction policies, `PredictHint` results, `Animations` options and failure reasons, `Assets` items, statuses and refusal reasons, limits and startup failures.

## Related references

- [actions.md](actions.md) for the shared start rules prediction reads.
- [action-input.md](action-input.md) for the requests a prediction follows.
- [client-views.md](client-views.md) for UI that reads ActorViews directly.
- [hints.md](hints.md) for server-sent effects and predicted hits.
