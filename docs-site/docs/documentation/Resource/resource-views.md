# Client ResourcesView

`actorView:GetResources()` returns read-only Resource state for HUDs, cooldown displays, and client presentation. `ResourceController` remains the authoritative owner of assignment, current values, bounds, and payments.

## Visibility and assignment

Declare a Resource as `ClientVisible` to expose it to clients aware of its Actor. Only assigned Resources appear; registering a definition does not assign it. Use `autoAssign` or the server controller's `AddResource` for assignment.

This catalog module defines Stamina with Property-backed maximum and regeneration:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ResourceTypes = require(ReplicatedStorage.Packages.KRF.server.Resource.types)

local definitions: { ResourceTypes.ResourceDefinition } = {
	{
		id = "Resource.Stamina",
		visibility = "ClientVisible",
		autoAssign = true,
		max = { propertyName = "MaxStamina", defaultBaseValue = 100 },
		regen = { rate = { propertyName = "StaminaRegen", defaultBaseValue = 12 } },
	},
	{
		id = "Resource.InternalBudget",
		visibility = "ServerOnly",
		autoAssign = true,
		max = { value = 50 },
	},
}

return definitions
```

Supply it through the `resources` field of your [game configuration](../initializing-krf). Active Tags can modify the supporting Properties; clients receive the resulting bounds and rate without needing a replicated PropertyController.

`ServerOnly` ids and state are excluded from protocol metadata, baselines, updates, and both generic and typed client queries. In this example, `HasResource("Resource.InternalBudget")` returns `false` on every client. Full server definitions are never replicated.

## Read a Stamina HUD

After client initialization, obtain an [ActorView](../Networking/actor-views) from the registry. `GetResources()` returns a stable facade even when no visible Resource definitions exist; that facade simply reports no assignments.

This example assumes `character` is the Model followed by your UI and `fill` is its bar Frame:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ViewTypes = require(KRF.client.Actor.types)
local Registry: ViewTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)

local function drawStamina(resources: ViewTypes.ResourcesView, fill: Frame): ()
	local stamina: ViewTypes.ResourceSnapshot? = resources:GetResource("Resource.Stamina")
	local fraction: number = 0
	if stamina ~= nil and stamina.max > stamina.min then
		fraction = (stamina.current - stamina.min) / (stamina.max - stamina.min)
	end
	fill.Size = UDim2.fromScale(fraction, 1)
end

local view: ViewTypes.ActorView? = Registry.GetActorViewByModel(character)
if view ~= nil then
	drawStamina(view:GetResources(), fill)
end
```

Call the draw function from your HUD's presentation loop for smooth motion. A missing view may arrive later through `OnActorViewAdded`; release Actor-specific UI connections when that view is removed. Querying Resources sends no network request.

`GetResource` returns an immutable point-in-time snapshot containing `resourceId`, `current`, `min`, `max`, and optional `regenRate`. Retaining it does not keep its `current` field moving; query again for a new estimate. `GetAssignedResources()` returns an immutable array of snapshots sorted by `resourceId`, derived with one shared time sample.

## Current is a presentation estimate

Positive regeneration is derived locally using synchronized server time and the latest authoritative value. It clamps to the latest resolved minimum and maximum. An absent, zero, or negative rate does not advance the estimate; negative rates do not imply decay.

The server advances regeneration in fixed 0.1-second steps. A smooth client estimate can be slightly ahead between those steps. Ordinary regeneration, including reaching maximum, creates no recurring Resource publication or final maximum packet.

Explicit `SetCurrent`, `Spend`, `Restore`, and `Drain` changes, successful assignment, and resolved bound or rate changes provide new authoritative corrections. A bound change and its resulting clamp arrive as one Resource state. Unrelated Resource estimates retain their previous timing.

There is no Resource-specific Remote or client mutation API. Use the server's ResourceController for gameplay and [declarative Action costs](../Action/action-resources) for payment on acceptance.

## Display a cooldown Resource

For a game that represents a cooldown as a regenerating Resource, a definition fragment can use a range of `0` to `1` and a rate of `1 / 8`:

```lua
{
	id = "Resource.FireballCooldown",
	visibility = "ClientVisible",
	autoAssign = true,
	max = { value = 1 },
	regen = { rate = { value = 1 / 8 } },
}
```

The Resource starts full by default. An Action can declare `costs = { ["Resource.FireballCooldown"] = 1 }`; server acceptance pays it and regeneration refills it over eight seconds. KRF does not assign special cooldown semantics to that id.

An existing UI render function can read it as follows:

```lua
local cooldown = resources:GetResource("Resource.FireballCooldown")
if cooldown ~= nil and cooldown.regenRate ~= nil and cooldown.regenRate > 0 then
	local seconds = (cooldown.max - cooldown.current) / cooldown.regenRate
	cooldownLabel.Text = string.format("%.1fs", seconds)
end
```

For advisory Action UI, a hint such as `resources:GetCurrent("Resource.Stamina") >= 20` still needs a missing-value check:

```lua
local stamina = resources:GetCurrent("Resource.Stamina")
adviceLabel.Text = if stamina ~= nil and stamina >= 20 then "Estimated affordable" else "Low Stamina"
```

This hint cannot guarantee a later request will succeed. Server-side grants, requirements, locks, and authoritative affordability determine acceptance; do not authorize an Action from a client estimate.

## React to authoritative changes

`OnResourceChanged` reports replicated state changes, not every occurrence of the server's Resource event:

```lua
local connection = resources.OnResourceChanged:Connect(function(change)
	if change.resourceId == "Resource.Stamina" then
		-- Reconcile transitions from change.previous and change.current.
		-- Both snapshots describe the same sampled client time.
		print(change.source)
	end
end)
```

Disconnect the connection when its UI binding ends. Use your presentation loop for continuous motion: the event does not fire as local time passes. Intermediate unsent authoritative changes may coalesce into the newest recoverable state.

Initial binding emits no historical changes; initialize from queries. A replacement baseline preserves the facade and subscriptions, then emits changes only for differing entries with `source = "Baseline"`. Live updates use `"Commit"`. Neither baseline replays server event history.

Model streaming preserves Resource state and subscriptions. Actor removal or terminal failure retires the state; removal tears down its subscriptions. A respawn receives a distinct ActorView and ResourcesView.

## Related

- [ResourcesView API](/api/Actor/resources-view)
- [Resource Runtime](./resource-runtime)
- [Resource Registry](./resource-registry)
- [Client ActorViews](../Networking/actor-views)
