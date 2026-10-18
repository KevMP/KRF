# Client TagsView

`actorView:GetTags()` returns the Actor's read-only visible Tags for UI, effects, and debug displays. Server `TagController` remains authoritative; client code cannot add, refresh, or remove Tags through this view.

## Find visible Tags

After [client initialization](../initializing-krf), obtain an [ActorView](../Networking/actor-views) from the registry. This example assumes `character` is the Model your UI follows:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Packages.KRF.client.Actor.ActorViewRegistry)

local view = Registry.GetActorViewByModel(character)
if view == nil then
	return -- Observe registry additions if this Model's view has not arrived yet.
end

local tags = view:GetTags()
stunnedIndicator.Visible = tags:HasTag("Status.Stunned")
```

`GetTags()` always returns the same object for this ActorView, including when no visible Tag definitions exist. An empty view reports no active Tags. Subscribe to `OnStateChanged` to reconcile an indicator after later changes; read current state once when binding.

## Definition visibility

Set visibility in the server [Tag catalog](./tag-registry):

| Visibility | Client observation |
| --- | --- |
| `ClientVisible` | Active aggregate state and Added, Refreshed, Removed, and Expired occurrences |
| `ServerOnly` | No definition id, state, or occurrences in bootstrap, generic domains, or TagsView |

For example, an active `Internal.Invulnerable` definition with `visibility = "ServerOnly"` still yields `tags:HasTag("Internal.Invulnerable") == false` and `tags:GetTag("Internal.Invulnerable") == nil` on the client.

Visible Tags use the ordinary framework replication stream. Their definition callbacks, property modifiers, individual instances, and tick scheduling remain server-only. No custom Remote or game-authored Tags domain is needed. The domain id `KRF.Tags` is reserved even when the catalog has no visible definitions.

## Read aggregate snapshots

`GetTag(tagId)` returns `nil` when inactive. An active snapshot contains:

| Field | Meaning |
| --- | --- |
| `tagId` | Semantic string id |
| `stackCount` | Number of authoritative active instances for that id |
| `remainingDuration` | Estimated seconds remaining for the server's aggregate timing, or `nil` for an indefinite aggregate |

`GetActiveTags()` returns every active visible id exactly once, sorted by semantic `tagId`. This differs from server `GetActiveTags()`, which orders by oldest application. The array and each snapshot are immutable; retain them as point-in-time values, not live countdown objects.

For mixed finite and indefinite stacks, aggregate timing follows the server's longest finite remaining duration. Expiring one instance can leave other stacks active, including indefinite stacks. Always query current presence and stacks rather than interpreting an estimated duration as the whole Tag's lifetime.

## Countdown is presentation timing

The client derives remaining time from a stable synchronized server-time anchor. Later queries can return less time without receiving another packet. Refresh and stack changes can replace that Tag's anchor; unrelated Tag changes leave it untouched.

Given the `tags` view above and a game-owned `countdownLabel`, a local render callback can update the display:

```lua
local RunService = game:GetService("RunService")

local countdownConnection = RunService.RenderStepped:Connect(function()
	local burning = tags:GetTag("Status.OnFire")
	countdownLabel.Text = if burning ~= nil and burning.remainingDuration ~= nil
		then string.format("%.1f", burning.remainingDuration)
		else ""
end)
```

Disconnect this rendering connection when the UI or owning Actor binding ends. These local queries do not request network updates.

Remaining time clamps to zero. Reaching zero does not remove the Tag, change stacks, or fire a local Expired event; `HasTag` stays true until authoritative state removes the entry. Use this value for presentation, never gameplay eligibility.

## Occurrences and reconciliation

| Event | Meaning |
| --- | --- |
| `OnTagAdded(tagId)` | An instance was added, including a new stack |
| `OnTagRefreshed(tagId)` | An existing instance refreshed, including at stack cap |
| `OnTagRemoved(tagId)` | Explicit/manual removal of one or all instances |
| `OnTagExpired(tagId)` | Authoritative timed expiry of an instance |
| `OnStateChanged(source)` | Visible aggregate truth changed; source is `"Commit"` or `"Baseline"` |

Occurrences are explicit server events, not deductions from state differences. A Refreshed event can arrive without `OnStateChanged` when aggregate state is unchanged. There is no `OnTagTicked` event and no recurring countdown or tick traffic. An `onTick` callback that independently mutates Tags still publishes those ordinary mutations.

Bind persistent OnFire effects from current truth. In this fragment, `setBurning`, `playIgnition`, and `playExtinguish` are presentation functions supplied by your game:

```lua
local function reconcileBurning()
	setBurning(tags:HasTag("Status.OnFire"))
end

reconcileBurning()

local addedConnection = tags.OnTagAdded:Connect(function(tagId)
	if tagId == "Status.OnFire" then
		playIgnition()
		reconcileBurning()
	end
end)

local expiredConnection = tags.OnTagExpired:Connect(function(tagId)
	if tagId == "Status.OnFire" then
		if not tags:HasTag(tagId) then
			playExtinguish()
		end
		reconcileBurning()
	end
end)

local stateConnection = tags.OnStateChanged:Connect(function(_source)
	reconcileBurning() -- Includes manual removal and recovery to current truth.
end)
```

Retain and disconnect these connections when the presentation binding ends. Use `OnTagRemoved` separately if manual removal should produce a different one-shot effect.

Initial and replacement baselines do not replay Added, Refreshed, Removed, or Expired history. Changed replacement truth fires `OnStateChanged("Baseline")`; the same TagsView and its subscriptions survive. Equal replacement truth emits no state change. Signals are asynchronous and yield-safe, so callbacks should query current state rather than assume it remains frozen to an earlier notification.

Model stream-out preserves TagsView truth. Authoritative Actor removal clears its state and tears down its event lifetime; respawn gets a new ActorView and TagsView. Release your Actor-specific bindings through the registry's Removing event.

## Related

- [TagsView API](/api/Actor/tags-view)
- [Tag Runtime](./tag-runtime)
- [ActorViews](../Networking/actor-views)
