---
title: ActorViews
---

# ActorViews

Use an ActorView when client code needs a character's replicated state. The view identifies the Actor even when its Model hasn't streamed in, and exposes only the domains available to that client.

## Find a view

After client startup, look up the local character by Model or subscribe to registry additions:

```lua
local view: KRF.ActorView? = KRF.ActorViewRegistry.GetActorViewByModel(character)

if view ~= nil and view:IsAvailable() then
	local resources: KRF.ResourcesView = view:GetResources()
	print(resources:GetCurrent("Stamina"))
end
```

`nil` means the client doesn't currently have that view. A character Model appearing locally does not prove that its replicated Actor has arrived. Conversely, a view can exist with `GetModel() == nil`; follow `OnModelChanged` if your consumer needs a physical Model.

For a consumer that watches every character, connect `OnActorViewAdded`, then enumerate `GetAllActorViews()` to include existing entries. Attach at most once per view and check `IsAvailable()`. Keep the view object with its subscriptions, rather than looking up whichever character is current when a delayed callback runs.

Clean up on `OnUnavailable` for a terminal stream fault and on `OnActorViewRemoving` for registry removal. Normal removal does not emit `OnUnavailable`. Disconnect the consumer's own connections and dispose of its local work on either path; KRF owns destruction of the views themselves.

## Read the right surface

Use `GetTags`, `GetResources` and `GetActions` for KRF's built-in state. These convenience views exist even when no visible entries are present. Use `GetDomain(id)` for [game-defined replication](../replication/guide); it returns `nil` for a domain the client doesn't have.

Visibility is enforced before publication. `ClientVisible` Tags, Resources and Actions are visible to every ready client aware of the Actor. `ServerOnly` entries aren't exposed even to the Actor's owner. A custom domain can use `audience = "Owner"` for private state.

An ActorView is read-only. Starting gameplay uses [Action requests](../actions/requests) or a [Command](../commands/guide), not a mutation to the view.

## Read state and react to events

State describes what is true now. Semantic events describe occurrences. A full initial state or recovery baseline doesn't replay historical Tag additions, Action starts or custom domain events.

```lua
local tags: KRF.TagsView = view:GetTags()

local function refresh(): ()
	print(tags:HasTag("Stunned"))
end

local connection: KRF.Connection = tags.OnStateChanged:Connect(refresh)
refresh()
```

Here a refresh reads current state whether it arrived through a live commit or a baseline. An effect that should play only for a new stun can subscribe to `OnTagAdded` instead. Its initial state still needs a separate read if the character was already stunned when the consumer attached.

Tag remaining durations and regenerating Resource values are estimates calculated when you query them. A snapshot table doesn't keep updating. Read again when you need a fresh number; regeneration doesn't fire the client's Resource change event every frame.

## Unavailability ends a view's lifetime

Respawns and removal retire an ActorView. Recoverable stream faults can retain the same available view and its last valid truth while KRF requests a replacement baseline. A terminal fault makes that view unavailable, clears its domains and can leave its identity and Model binding in the registry until removal. Lookup success alone therefore doesn't establish availability.

Once unavailable, don't use that object as a new Action target. A later replacement is a different view object and needs new subscriptions and control profiles.

For a baseline or live Actor update, all affected state and indexes are installed before its public notifications. Queries in those callbacks read installed state; an event's previous/current payload can describe an earlier transition if another callback has already caused a newer update.

Registry removal has its own boundary: `OnActorViewRemoving` announces retirement while the view is still indexed, before KRF removes and destroys it. A live view can still report available in that callback. Use the event to end your consumer rather than waiting for a later unavailable notification.

See [ActorViews API](./client-views-api), [Events](../getting-started/events) and [client controls](../controls/guide).
