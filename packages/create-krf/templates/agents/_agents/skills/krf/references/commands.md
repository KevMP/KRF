# Commands

A Command is a request from a client that the server answers once: accepted with an optional result, or rejected with a reason. Use one for something a player asks for that isn't something their character does, such as buying an item, choosing a class or changing a setting.

## Check whether it's an Action

If the character does it, it's an [Action](actions.md), even when it's instant: opening a door, sitting down, casting a spell. Actions get costs, Tag gates, locks, interrupts and input bindings that a Command doesn't have.

| Use | When |
| --- | --- |
| An Action | The character does it, it can conflict with other things the character does, or it has a cost, a duration or an input |
| A Command | The player asks the server to decide or change something, and needs to know whether it worked |
| A [Hint](hints.md) | The client sends something cosmetic that can be lost and needs no answer, such as where it's aiming so other players see it |

A Command answers one request. If the client needs to keep seeing what changed, such as the new contents of an inventory, publish that through a [Resource](resources.md) or a [replication domain](replication.md). The client can't read a Command's result again later.

## Generate it

```bash
npm run createCommand -- --name BuyItem --target Actor --request-field "ItemId:String(32)" --authorize OwnerActor --yes --json
```

The generator writes the Command to `src/server/Commands` and adds it to `Server.Init`. Until you fill in `handle`, it rejects every request with `NotImplemented`.

- `--target Actor` runs the Command for one character, available as `ctx.actor`. Use `--target None` for something that isn't about a character, such as a settings change.
- `--request-field` declares what the client sends, and `--result-field` declares what an accepted request returns. Leave the result out when the client can read the outcome from state it already sees.
- `--authorize` defaults to `deny`, which rejects every request until you write your own `authorize`.

For every flag and how to read the result, see [generators.md](generators.md#createcommand).

## Decide who may send it

`authorize` answers one question: may this player send this Command for this target? Pick a built-in policy when one fits:

| Policy | Allows |
| --- | --- |
| `KRF.CommandAuthorization.OwnerActor` | The player whose current character is `ctx.actor` |
| `KRF.CommandAuthorization.AnyReadyClient` | Any player. Use it only when that's really the rule |

When neither fits, write your own `authorize`. It must return `true, nil` or `false, reason`, change nothing and never yield.

Game rules, such as whether the player can afford the item, belong in `handle`, not `authorize`.

## Handle the request

`handle` checks the game's rules, makes the change and returns the answer. Check everything before changing anything. Returning a rejection after a change doesn't undo it. This handler charges Gold, a Resource, and adds the item to the game's own Inventory Controller from [replication.md](replication.md), given a `HasRoom` method:

```lua
handle = function(ctx: KRF.CommandContext, request: { ItemId: string }): KRF.CommandHandlerResult
	local actor: KRF.Actor = assert(ctx.actor)
	local price: number? = Items.PRICES[request.ItemId]

	if price == nil then
		return { accepted = false, reason = "UnknownItem" }
	end

	local resources = actor:GetController("ResourceController") :: KRF.ResourceController
	local inventory = actor:GetController("Inventory") :: Inventory.Inventory

	if not inventory.HasRoom(request.ItemId, 1) then
		return { accepted = false, reason = "InventoryFull" }
	end

	local spent: boolean, reason: string? = resources:Spend("Gold", price)

	if not spent then
		return { accepted = false, reason = reason or "CannotAfford" }
	end

	inventory.AddItem(request.ItemId, 1)

	return { accepted = true }
end,
```

- `Spend` removes the whole amount or nothing, so it's both the affordability check and the payment. Call it last among the checks that can fail.
- The schema only checks the payload's shape. Treat every value as a claim: look prices up on the server, never trust one the client sent.
- `handle` must not yield. Start longer work in the server system that owns it and return straight away.
- A rejection reason is a nonempty string of at most 64 bytes.

If `authorize` or `handle` errors or yields, KRF reports `Unknown` to the client instead of a rejection, because a handler may already have changed something.

## Send it from the client

Connect to the result events first, then send. An `Unknown` can fire before `Send` returns, so a listener connected afterwards, or one waiting for the returned ID, can miss it. This Buy button allows one purchase at a time and matches outcomes by Command ID:

```lua
local waiting: boolean = false

local function onOutcome(outcome: KRF.CommandResult): ()
	if not waiting or outcome.commandId ~= "BuyItem" then
		return
	end

	waiting = false
	buyButton.Active = true

	if outcome.status == "Rejected" then
		showError(outcome.reason or "Rejected")
	end
end

KRF.CommandRuntime.OnCommandResult:Connect(onOutcome)
KRF.CommandRuntime.OnCommandUncertain:Connect(onOutcome)

local function buy(itemId: string): ()
	waiting = true
	buyButton.Active = false

	local requestId: number?, reason: string? = KRF.CommandRuntime.Send("BuyItem", actorView, { ItemId = itemId })

	if requestId == nil then
		waiting = false
		buyButton.Active = true
		warn(`BuyItem not sent: {reason}`)
	end
end
```

- Pass the character's ActorView for an `Actor` target and `nil` for a `None` target.
- A request ID means the client sent the request, not that the server accepted it. When several requests can be in flight, match outcomes by the ID `Send` returns, and handle an outcome that arrives before you've stored it.
- A request `Send` refuses locally returns `nil` and a reason, and fires no result event.

## Handle Unknown

`OnCommandUncertain` fires with `Unknown` when the client can't get a clear answer, such as after a timeout or a server error. `Unknown` doesn't mean rejected; the purchase may have gone through.

Never send the request again because of `Unknown`, or the player may buy twice. Read the state the client already sees, such as the Gold Resource or the inventory domain, to show what actually happened. A late Accepted or Rejected can still arrive after `Unknown`.

## Exact APIs

- [Commands guide](docs/commands/guide.md) and [Commands API](docs/commands/api.md): definition fields, authorization helpers, result events, local refusal reasons and ordering.
- [Schemas API](docs/schemas/api.md): request and result field types.

## Related references

- [actions.md](actions.md) for anything the character does.
- [replication.md](replication.md) for state the client keeps seeing after the request.
- [hints.md](hints.md) for messages that need no answer.
- [resources.md](resources.md) for `Spend` and the other Resource methods.
