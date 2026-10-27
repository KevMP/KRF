---
sidebar_position: 3
---

# Actor replication lifecycle

KRF turns authoritative Actor publication into a separate reliable stream for each ready client. Roblox owns physical Model replication and `StreamingEnabled` independently.

Default client startup installs the Actor decoder and [ActorView runtime](./actor-views) before declaring readiness. A complete baseline publishes a read-only client ActorView; later committed work updates that same view.

## Awareness and identity

The server tracks every ready client as aware of every registered Actor. A client joining later gets streams for the current Actors, and registering another Actor creates streams for the current ready clients. This server-side awareness does not imply that the client has consumed Actor data. Connection closure releases that connection's streams.

`actor:GetId()` is the Actor's public runtime identity. Networking establishes a private connection-local handle for recurring traffic. Handles are never reused within a connection and are not game API. A respawn creates a new Actor identity.

## Baseline, live work, and recovery

1. At awareness, resync or Character-association changes, KRF synchronously anchors immutable canonical truth and its publication sequence fence. Joining or recovering clients do not rerun game snapshot callbacks. Domain callbacks still capture committed gameplay synchronously; deferred Networking work cannot read mutable future state into an existing anchor.
2. Recipient projection, body encoding and chunk delivery run later within bounded scheduling. Eligible recipients may share a materialized body for the same canonical truth/audience. Sharing does not bypass preparation, byte, record or send budgets. The complete baseline precedes live work after its fence.
3. Visible committed state and semantic events follow the baseline in Actor order. State-only work may coalesce; required event boundaries remain ordered.
4. If queued work exceeds its limits or a live record repeatedly exceeds the complete delivery budget, KRF discards obsolete unsent history and captures a newer baseline. A temporarily small budget waits. Recovery restores current truth; occurrences before that capture are not replayed.
5. Unregistering an Actor discards unsent work and reliably retires its awareness and handle.

Each recipient has an independent revision sequence for each Actor. Filtering and state coalescing happen before revision allocation, so hidden Owner work consumes no revision for other clients. A complete replacement baseline establishes a newer authoritative revision.

Oversized baselines, exhausted stream counters, and failed reliable sends halt the affected recipient's Actor stream and emit a warning. Automatic baseline recovery handles oversized live work and queue pressure; it does not restart a halted stream. The server Actor remains registered even when delivery fails.

Terminal cleanup is sent reliably and retried before pending transfer capacity is reused, so halted Actors do not indefinitely block unrelated transfers. Cleanup preserves Actor awareness and any existing Model binding.

Temporary backlog-capacity refusal waits under bounded recovery policy. A visible baseline that exceeds the supported maximum instead faults explicitly as `ActorBaselineTooLarge`; retrying cannot make that fixed size valid. Server replacement attempts use capped delays measured in scheduler pumps, distinct from the client's timed resync opportunities. Continued pressure may postpone recovery; this is no wall-clock completion guarantee. See [maintainer scheduling and ownership](./maintaining-networking).

On the client, terminal halt retires domain truth and makes the ActorView unavailable while keeping its registered identity and Model lifecycle. Recoverable revision or application faults retain the last valid truth during bounded replacement attempts; exhaustion also makes only that client ActorView unavailable. See [ActorViews recovery](./actor-views#initial-state-and-recovery) for observation and failure guarantees.

## State coalescing and event overload {#state-coalescing-and-event-overload}

Unsent state-only changes can merge toward newest truth while respecting semantic-event barriers. A required occurrence cannot disappear while its stream remains continuous. When eventful history no longer fits, only the affected recipient/Actor stream becomes discontinuous, abandons obsolete incremental work and stops retaining further event history. A later replacement restores current truth, not missed occurrences. Actor retirement cancels that work instead of finishing obsolete transfers.

For example, a game catalog can define this visible Tag (pass the returned catalog through normal startup):

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TagTypes = require(ReplicatedStorage.Packages.KRF.server.Tags.types)

local tags: { TagTypes.TagDefinition } = {
	{ id = "Status.Charged", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 30 },
}
return tags
```

This server helper illustrates a burst on an already registered Actor. It is a stress illustration, not a recommended gameplay update loop. A sufficiently large burst can cross internal event limits; no particular count is a public overload threshold:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)

local function publishBurst(actor: ActorTypes.Actor, count: number): ()
	local tags = actor:GetController("TagController") :: TagTypes.TagController?
	assert(tags ~= nil, "TagController required")
	for _ = 1, count do
		local accepted, reason = tags:AddTag("Status.Charged")
		assert(accepted, reason)
	end
end

return publishBurst
```

On the client, persistent presentation reads current state. Semantic events drive occurrences only when actually delivered. Attach this to a current view with the Tags domain; call the returned disposer on view removal/unavailability. `draw` and `playRefresh` are game presentation callbacks:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Actor.types)

local function attach(view: Types.ActorView, draw: (boolean) -> (), playRefresh: () -> ()): () -> ()
	local domain = view:GetDomain("KRF.Tags")
	assert(domain ~= nil, "Visible Tags domain required")
	local tags = view:GetTags()
	draw(tags:HasTag("Status.Charged"))
	local changed = domain.OnChanged:Connect(function(change: Types.DomainChange): ()
		local current: any = change.current
		draw(current["Status.Charged"] ~= nil)
		if change.source == "Baseline" then
			-- Replacement current truth, not replay of missed refreshes.
			print("Reconciled charged presentation")
		end
	end)
	local refreshed = tags.OnTagRefreshed:Connect(function(id: string): ()
		if id == "Status.Charged" then playRefresh() end
	end)
	return function(): ()
		changed:Disconnect()
		refreshed:Disconnect()
	end
end

return attach
```

The pressure transition is `Live → NeedsBaseline → replacement baseline → Live`. An equal recovered value need not fire `OnChanged`; no synthetic refreshes are emitted. Do not count client callbacks to authorize gameplay or assume every server occurrence will be replayed after discontinuity. Keep authoritative decisions on the server.

## All and Owner audiences

| Audience | Eligible recipient |
| --- | --- |
| `All` | Every ready client aware of the Actor |
| `Owner` | The Player whose current Character is the Actor's registered Model |

Owner filtering uses direct Player and Actor objects. Numeric user ids do not establish ownership, and a later session with the same user id inherits no association. NPCs and Actors without a current Player association have no Owner recipient.

A Character association change reconciles affected streams that remain registered. The previous Actor's replacement excludes Owner domains; the new registered Character's baseline includes their current truth. If Roblox removes the old Character Model, Actor Runtime retires that Actor instead. Unregistered Character Models create no Actor association. Other recipients keep their existing streams.

Audience filters values and occurrences, not protocol metadata: every client still receives the same schema catalog.

## Model streaming

Physical Model arrival is independent of server awareness. A Model can arrive before or after its Actor stream starts. Streaming it out does not retire or reset that stream; Actor teardown or connection closure ends it. `ActorViewRegistry.GetActorViewByModel(model)` resolves a published view while the Model is locally bound. Lookup by actorId remains available while its Model is absent.

Successful Actor registration installs framework identity metadata before returning; teardown removes it. Model clones do not inherit that metadata. Leave it under framework ownership and register new gameplay Models through Actor Runtime.

## Related

- [Networking startup](./startup)
- [Replication domains](./replication-domains)
- [Scheduler, overload and diagnostics](./maintaining-networking)
- [Actor Runtime](../Actor/actor-runtime)
