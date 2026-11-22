---
title: Replication domains
sidebar_label: Guide
---

# Replication domains

A realm display needs the progression state your Cultivation Controller keeps on the server. A replication domain describes which state clients can read and which occurrences they can observe. The Controller keeps ownership of gameplay; clients receive a read-only DomainView.

KRF supplies domains for visible [Tags](../tags/guide), [Resources](../resources/guide) and [Actions](../actions/guide) automatically. Custom domains expose state owned by your game's Controllers.

## Describe the state clients need

Pass a domain catalog to `Server.Init({ replicationDomains = domains })`. This example assumes a game-owned `Cultivation` Controller whose `GetRealm()` returns its current realm:

```lua
local Schema = KRF.Schema
type CultivationProjection = KRF.Controller & {
	GetRealm: () -> number,
	ObserveCommitted: (callback: (any?) -> ()) -> (() -> ()),
}

local domains: { KRF.ReplicationDomainDefinition } = {
	{
		id = "Cultivation",
		state = Schema.Struct({ realm = Schema.U8 }),
		audience = "All",
		snapshot = function(actor: KRF.Actor)
			local cultivation = actor:GetController("Cultivation") :: CultivationProjection?
			assert(cultivation ~= nil, "Cultivation Controller required")
			return { realm = cultivation.GetRealm() }
		end,
		observe = function(actor: KRF.Actor, onCommitted)
			local cultivation = actor:GetController("Cultivation") :: CultivationProjection?
			assert(cultivation ~= nil, "Cultivation Controller required")
			return cultivation.ObserveCommitted(onCommitted)
		end,
	},
}
```

`GetRealm` and `ObserveCommitted` are methods on this example's game-owned Controller. `ObserveCommitted` returns a disconnect function and delivers notifications synchronously after state commits, before public gameplay callbacks. The [realm replication chapter](/tutorial/show-realms) builds such a Controller subscription.

KRF captures the initial snapshot after Controllers attach during Actor registration. A bad snapshot or subscription rejects registration and releases subscriptions already acquired. `snapshot` and `observe` must not yield. Omit `observe` only when the projected state stays fixed for the Actor's lifetime.

## Commit first, notify second

When the realm changes, the Controller installs its new state and calls its committed observers. The adapter forwards that notification to `onCommitted()`, so KRF knows to capture the domain again. Ordinary standalone notifications capture state before returning. Within a framework operation that changes several domains, KRF captures their final state together at that operation's commit boundary.

Keep this notification separate from public gameplay Events. An asynchronous Signal, `task.defer` or Heartbeat notification can capture a later mutation instead of the state boundary it was meant to describe. Public callbacks can also reenter gameplay, so publication must capture the committed state before those callbacks run.

The projection may read several Controllers. They must already contain a coherent state when it is captured. An unchanged snapshot with no occurrences produces no new publication.

## Declare occurrences separately

The current realm lets a late-joining client draw the right title. A breakthrough occurrence lets an already connected client play a one-time effect. Declare that occurrence as a semantic event:

```lua
events = {
	{ id = "Breakthrough", payload = Schema.Struct({ realm = Schema.U8 }) },
},
```

At that committed boundary, the adapter supplies:

```lua
onCommitted({
	{ id = "Breakthrough", payload = { realm = newRealm } },
})
```

KRF captures event payloads immediately and keeps their order within the publication. Clients can rebuild persistent presentation from current state after joining or recovering; historical occurrences are not replayed. Anything a client needs to recover must therefore be represented in state.

Invalid state or event data rejects publication and leaves clients at the last valid captured state. It does not undo the Controller's gameplay change. Fix the producer so a later valid notification can publish current state again; rejected occurrences are not replayed. The [API](./api#runtime-capture-failures) explains fault propagation and recovery across several domains.

## Choose the audience

`All` is the default: every ready client aware of the Actor can receive the domain. `Owner` restricts values and events to the Player whose current Character is the Actor's registered Model. A non-Character NPC has no Owner recipient. Custom Action control permission does not change this replication audience.

When that Character association changes, KRF replaces the affected clients' baselines so they gain or lose the Owner domains. A domain's audience is fixed by its definition; the Actor's current owner can change.

A domain's snapshot receives only the Actor, not the recipient. Use separate public and private domains when their projections differ. Schema metadata is shared with every client during startup, even for Owner domains; audience filtering protects values, not the names or shapes of definitions.

Every ready client is currently aware of every registered Actor. Roblox Model streaming is independent: an available ActorView can have no local Model.

## Read published state on the client

Obtain the domain with `actorView:GetDomain("Cultivation")`. When it is present, a consumer can attach like this and retain the returned cleanup function:

```lua
local function observeRealm(domain: KRF.DomainView): () -> ()
	local changed = domain.OnChanged:Connect(function(change)
		print("Current realm:", change.current.realm)
	end)
	print("Current realm:", domain:GetState().realm)

	return function(): ()
		changed:Disconnect()
	end
end
```

Subscribe and read current state when attaching a consumer, since the domain may already have arrived. `OnChanged` reports later installed snapshots; `GetEvent("Breakthrough")` returns the declared occurrence Event. A domain can disappear when its audience changes, so keep subscriptions with that domain's membership and the ActorView's lifecycle. [Client views](../actors/client-views) explains availability and cleanup.

Reliable streams deliver a complete baseline before live changes. Several unsent state-only changes may merge into the newest value. Under overload or a recoverable stream fault, KRF can replace incremental history with another baseline: current state returns, missed occurrences do not. A terminal stream failure makes the affected client view unavailable; the server Actor and other streams can continue.

See the [domain API](./api) for exact fields and guarantees, and [Schemas](../schemas/guide) for the supported data vocabulary.
