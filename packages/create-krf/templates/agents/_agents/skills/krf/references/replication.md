# Replication domains

A replication domain publishes state that a game-owned Controller keeps on the server, such as an inventory, a quest log or a level, to the clients allowed to see it. Clients read it through the Actor's [ActorView](client-views.md). They can't change it; changes still go through an [Action](actions.md) or a [Command](commands.md).

## Check whether KRF already sends it

Before writing a domain, check whether a KRF primitive already gets the data to the client. Most of what a client needs is already covered:

| The client needs | Use |
| --- | --- |
| A status and how long it has left, such as Stunned or Burning | A `ClientVisible` [Tag](tags.md) |
| A meter, cooldown or charge count, including its min and max | A `ClientVisible` [Resource](resources.md) |
| Which Actions a character is running | A `ClientVisible` [Action](actions.md) |
| The answer to something the client asked for | A [Command](commands.md) result |
| A one-time effect that isn't part of any state, such as an explosion at a point | A [Hint](hints.md) |

If one of these fits, use it, even if it means modelling the data a little differently. A stat the UI shows can often be a Resource's bound. A cooldown is a Resource, not a timestamp in a domain.

Write a domain only when none of them fits: state that a Controller of yours owns, such as an inventory or a quest log, or state that only the Actor's owner should see. `ClientVisible` reaches every client.

## Generate it

```bash
npm run createDomain -- --name Inventory --audience Owner --state-field "Items:Map(String(32),U16,40)" --event "ItemAdded(ItemId:String(32),Count:U16)" --yes --json
```

The generator writes the domain to `src/server/ReplicationDomains` and adds it to `Server.Init`. Then fill in two callbacks:

- `snapshot` returns the Actor's current state in the shape of `state`.
- `observe` tells KRF when that state changes, so it can take a new snapshot.

The generator defaults `--audience` to `Owner`. Pass `--audience All` for state every client should see. For every flag and how to read the result, see [generators.md](generators.md#createdomain).

## Choose the audience

| Audience | Who receives it |
| --- | --- |
| `All` | Every client |
| `Owner` | Only the Player whose current Character is the Actor's Model. An NPC has no owner, so nobody receives it |

`snapshot` doesn't know who receives it, so one domain can't show different values to different players. When part of the state is public and part is private, such as an equipped weapon everyone sees and a bag only the owner sees, write two domains.

Every client receives the names and shapes of every domain at startup, including `Owner` ones. The audience hides values, not definitions, so never put secrets in an ID or field name.

## Let the Controller report changes

KRF can only publish what it's told about. Give the Controller an `Observe` method that calls its listeners right after its state changes:

```lua
export type InventoryChange = { itemId: string, delta: number }

export type Inventory = KRF.Controller & {
	GetItems: () -> { [string]: number },
	AddItem: (itemId: string, count: number) -> (),
	Observe: (listener: (change: InventoryChange) -> ()) -> () -> (),
}
```

```lua
local items: { [string]: number } = {}
local listeners: { (change: InventoryChange) -> () } = {}

local function notify(change: InventoryChange): ()
	for _, listener in table.clone(listeners) do
		listener(change)
	end
end

local inventory: Inventory = {
	GetItems = function(): { [string]: number }
		return table.clone(items)
	end,
	AddItem = function(itemId: string, count: number): ()
		items[itemId] = (items[itemId] or 0) + count
		notify({ itemId = itemId, delta = count })
	end,
	Observe = function(listener: (change: InventoryChange) -> ()): () -> ()
		table.insert(listeners, listener)

		return function(): ()
			local index: number? = table.find(listeners, listener)

			if index ~= nil then
				table.remove(listeners, index)
			end
		end
	end,
	Destroy = function(): ()
		table.clear(listeners)
	end,
}
```

Call the listeners immediately and synchronously, after the state is updated and before anything else runs:

- Never notify through `task.defer`, `task.spawn`, Heartbeat or a public Signal. KRF would snapshot whatever the state is by then, not the change you reported.
- Notify before calls that can run other gameplay, such as `SetBaseProperty`, firing your own events or applying a Tag. Those can change the state again before KRF has captured this change.
- Notify on every change, including removals.

## Connect the domain

```lua
local Inventory = require(script.Parent.Parent.Controllers.Inventory)

local function inventoryOf(actor: KRF.Actor): Inventory.Inventory
	return actor:GetController("Inventory") :: Inventory.Inventory
end
```

```lua
snapshot = function(actor: KRF.Actor): { [string]: any }
	return { Items = inventoryOf(actor).GetItems() }
end,
observe = function(actor: KRF.Actor, onCommitted: (events: { any }?) -> ()): () -> ()
	return inventoryOf(actor).Observe(function(change: Inventory.InventoryChange): ()
		if change.delta > 0 then
			onCommitted({ { id = "ItemAdded", payload = { ItemId = change.itemId, Count = change.delta } } })
		else
			onCommitted(nil)
		end
	end)
end,
```

- `onCommitted(nil)` publishes the new state alone. Pass events only for something that happened.
- Return the disconnect function from `observe`. KRF calls it when the Actor is removed.
- `snapshot` and `observe` must not yield. If either one errors or returns state that doesn't match the schema when the Actor registers, the registration fails.
- Leave out `observe` only for state that never changes during the Actor's lifetime.

## Put what clients must recover in state

State is what's true now. A client that joins late, respawns or recovers from a network problem receives the current state and never the events it missed. Events are only for one-time reactions, such as a pickup sound.

Anything the UI must show correctly after a rejoin belongs in state. If a "new item" badge has to survive a rejoin, put the unseen items in state rather than relying on `ItemAdded`.

If a snapshot or an event fails its schema later, KRF keeps clients at the last valid state and raises the error in the code that called `onCommitted`. It doesn't undo the Controller's change. Fix the producer; the next valid notification publishes the current state, but rejected events are gone.

## Pick schema types

Use the smallest type that fits: integer widths for counts and IDs, `F32` for fractions, `Enum` for a fixed set of names, and `String(maxBytes)` with a real bound. Collections need a maximum size:

| Type | Use for |
| --- | --- |
| `Array(Type, maxLength)` | An ordered list, such as party members |
| `Map(KeyType, ValueType, maxEntries)` | Entries looked up by key, such as item counts |
| `Optional(Type)` | A field that can be absent |
| `Struct({ ... })` | A record with fixed fields |

There's no Any or Instance type. Send a direction as numbers, and refer to things by ID rather than by Instance.

## Read it on the client

`view:GetDomain(id)` returns a DomainView, or `nil` when this client can't see the domain. Draw from `GetState()` and `OnChanged`, and play effects from `GetEvent`:

```lua
local function attachInventory(domain: KRF.DomainView): () -> ()
	local function refresh(): ()
		drawInventory(domain:GetState().Items)
	end

	local changed: KRF.Connection = domain.OnChanged:Connect(refresh)
	local itemAdded: KRF.Event<any>? = domain:GetEvent("ItemAdded")
	local added: KRF.Connection? = if itemAdded ~= nil
		then itemAdded:Connect(function(payload: { ItemId: string, Count: number }): ()
			playPickupSound(payload.ItemId)
		end)
		else nil

	refresh()

	return function(): ()
		changed:Disconnect()

		if added ~= nil then
			added:Disconnect()
		end
	end
end
```

Call `refresh()` once after connecting; `OnChanged` doesn't fire for the state the domain arrived with.

A domain can arrive or leave while the ActorView stays the same, such as an `Owner` domain when a character's owner changes. Attach when `view.OnDomainsChanged` lists the ID in `added`, run the cleanup when it lists it in `removed`, and run it on the view's removal and `OnUnavailable` too. See [client-views.md](client-views.md) for that lifecycle.

## Exact APIs

- [Replication guide](docs/replication/guide.md) and [Replication API](docs/replication/api.md): definition fields, `onCommitted`, delivery guarantees and failure reasons.
- [Schemas guide](docs/schemas/guide.md) and [Schemas API](docs/schemas/api.md): every schema type and its limits.
- [ActorViews API](docs/actors/client-views-api.md): `GetDomain`, `GetDomainIds` and `OnDomainsChanged`.

## Related references

- [actors-and-controllers.md](actors-and-controllers.md) for writing the Controller that owns the state.
- [client-views.md](client-views.md) for finding views and cleaning up.
- [hints.md](hints.md) for effects that aren't part of an Actor's state.
- [tags.md](tags.md) and [resources.md](resources.md) for state KRF already publishes.
