# Client views

An ActorView is the client's read-only copy of an Actor. It shows the Actor's `ClientVisible` Tags, Resources and running Actions, plus any replication domains the game publishes to that client. Client UI, effects and sounds read from it. Changing anything still goes through an [Action request](action-input.md) or a [Command](commands.md).

## Find a view

A generated game tracks the local player's view in `src/client/LocalCharacter.luau`:

- `LocalCharacter.Get()` returns the current view, or `nil`.
- `LocalCharacter.Observe(callback)` calls back with each new view, including after a respawn.

For any other character, look it up by Model:

```lua
local view: KRF.ActorView? = KRF.ActorViewRegistry.GetActorViewByModel(model)
```

A Model existing on the client doesn't mean its view has arrived, and a view can exist before its Model streams in. Handle `nil` either way.

## Follow every character

For something every character needs, such as nameplates or health bars, connect to `OnActorViewAdded` first, then go through `GetAllActorViews()` for the views that already exist:

```lua
local function attach(view: KRF.ActorView): ()
	if not view:IsAvailable() then
		return
	end

	createNameplate(view)
end

KRF.ActorViewRegistry.OnActorViewAdded:Connect(attach)

for _, view: KRF.ActorView in KRF.ActorViewRegistry.GetAllActorViews() do
	attach(view)
end
```

Make sure you attach to each view only once. Tear down the UI and disconnect its connections on `OnActorViewRemoving`, and on the view's `OnUnavailable`. Normal removal doesn't fire `OnUnavailable`, so handle both.

A respawn creates a new view. Never keep using the old one; attach to the new one instead.

## Read what you need

| Surface | Reads |
| --- | --- |
| `view:GetTags()` | `HasTag`, `GetTag` with stack count and remaining time, and `GetActiveTags` |
| `view:GetResources()` | `GetCurrent`, `GetMin`, `GetMax`, `GetRegenRate` and `GetResource` |
| `view:GetActions()` | `IsActionActive` and the running activations |
| `view:GetDomain(id)` | Game state published by a replication domain, or `nil` if this client can't see it |

The Tag, Resource and Action surfaces always exist, even when nothing is visible.

## Draw state, play effects on events

Every surface has current state and events. Use state to draw what's true now, and events for things that should happen once:

```lua
local tags: KRF.TagsView = view:GetTags()

local function refresh(): ()
	stunIcon.Visible = tags:HasTag("Stunned")
end

local connection: KRF.Connection = tags.OnStateChanged:Connect(refresh)
refresh()
```

Call `refresh()` once after connecting. Events never replay what happened before you connected, so a character who was already stunned would otherwise show no icon.

To play a sound when a stun lands, use `OnTagAdded` instead. It fires only for new stuns, never for ones that already existed.

## Animate moving values every frame

Regenerating Resources and Tag countdowns are estimated on the client when you read them. Their events don't fire as the value moves, so a bar or a timer must read the value every frame:

```lua
RunService.RenderStepped:Connect(function(): ()
	local resources: KRF.ResourcesView = view:GetResources()
	local current: number = resources:GetCurrent("Mana") or 0
	local max: number = resources:GetMax("Mana") or 1

	manaFill.Size = UDim2.fromScale(current / max, 1)
end)
```

A Tag whose countdown reaches zero stays until the server removes it. Never hide it locally because the timer ran out.

## Know what clients can't see

- `ServerOnly` Tags, Resources and Actions don't exist on any client, including their owner's.
- `ClientVisible` state reaches every client, not only the owner. For state only the owner should see, publish a replication domain with an `Owner` audience. See [replication.md](replication.md).
- Properties, grants, Action payloads, Action phases and interrupt reasons are never sent. Publish what the UI needs through a domain.

## Show the result of a request

ActionsView shows which Actions are running. It doesn't say whether the player's own request was accepted, and a `ServerOnly` Action never appears in it. For feedback on a request, such as greying out a button until the server answers, use `ClientActionRuntime.OnActionRequest`. See [action-input.md](action-input.md).

## Exact APIs

- [ActorViews guide](docs/actors/client-views.md) and [ActorViews API](docs/actors/client-views-api.md): registry lookups, lifecycle, and the Tag and Action surfaces.
- [Resources API](docs/resources/api.md#resources-view): ResourcesView methods and change records.

## Related references

- [replication.md](replication.md) for publishing game state to clients.
- [tags.md](tags.md) and [resources.md](resources.md) for choosing `ClientVisible`.
- [action-input.md](action-input.md) for request outcomes.
