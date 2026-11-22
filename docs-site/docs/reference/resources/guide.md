---
title: Resources
---

# Resources

Use a Resource for a value a character can spend and regain, such as stamina, mana or ability charges. Each Actor has its own current value, kept between a minimum and maximum. The server owns changes; clients can read the visible state.

## Define a meter

This Stamina Resource reads its limit and regeneration rate from registered [Properties](../properties/guide):

```lua
local Stamina: KRF.ResourceDefinition = {
	id = "Stamina",
	max = { propertyName = "MaxStamina" },
	regen = { rate = { propertyName = "StaminaRegen" } },
	visibility = "ClientVisible",
	autoAssign = true,
}
```

Pass the definition in `Server.Init({ resources = ... })`. In a generated project, save it in `src/server/Resources/Stamina.luau`; that folder's catalog loads it for startup. Create MaxStamina and StaminaRegen in the Property catalog first.

Use `{ value = 100 }` for a constant bound or rate. Use `{ propertyName = "MaxStamina" }` when it should follow an Actor's resolved stat. The Resource automatically assigns a referenced Property if the Actor doesn't have it yet, preserving an existing value.

The minimum defaults to 0 and a new Resource starts at its resolved maximum. Set `initialValue = 0` for a meter players must fill themselves. See [definition fields](./api#resource-definition) for the complete defaults and validation rules.

## Assign it to an Actor

`autoAssign = true` attempts assignment during Actor registration. For an earned meter, leave it false and call `AddResource` at the unlock. This example assumes Mana is already in the Resource catalog:

```lua
local resources = actor:GetController("ResourceController") :: KRF.ResourceController
local added: boolean, reason: string? = resources:AddResource("Mana", 0)
assert(added, reason)
```

The optional value overrides the definition's starting value and is clamped to that Actor's bounds. If an Actor's Property sources cannot form valid bounds, automatic assignment warns and leaves that Resource unassigned. Check `HasResource` when availability matters; successful Actor registration alone doesn't prove every requested automatic assignment succeeded.

A Resource remains assigned until Actor teardown; there is no unassignment method. Control access to abilities that use it through grants or Tags.

## Charge an ability on acceptance

Put an Action's price on its definition:

```lua
costs = { Stamina = 20 },
resourceRequirements = { Stamina = { minPercent = 0.5 } },
```

The requirement checks that the meter is at least half full. The cost spends 20 only if KRF accepts the Action. Costs across several Resources are committed together, before start notifications, and aren't automatically refunded when the Action ends or is interrupted.

Calling `Spend` before requesting an Action can charge for a request the server rejects. Use [Action costs](../actions/guide) for admission, and ResourceController for unrelated changes such as a pickup, trap or explicit refund.

| Operation | Use it for |
| --- | --- |
| `Spend` | Exact payment outside Action admission; insufficient value changes nothing |
| `Restore` | Add up to the maximum |
| `Drain` | Remove up to the minimum, even when the full amount isn't available |
| `SetCurrent` | Set a value and clamp it to the bounds |
| `CanSpend` | Check an exact payment without changing state |

Spendable value is measured above the minimum. With min 10 and current 30, at most 20 is spendable.

## Let Properties change the bounds

A Tag that modifies MaxStamina or StaminaRegen changes the Resource through the resolved Property. A lower maximum clamps current Stamina down. A higher maximum leaves the current amount alone; explicitly restore it if your design calls for a refill.

Initial Property overrides supplied during Actor registration are available when Resources are created. Later changes resolve affected bounds and rates before public notifications. Invalid dynamic bounds or non-finite source values leave the last valid Resource configuration in place.

Regeneration advances automatically in fixed 0.1-second steps while the Actor is enabled. The scheduler performs at most one step per Heartbeat, retaining accumulated time for later steps. A delayed frame does not run every missed step at once, so this is not a guarantee of exact wall-clock recovery. Zero or negative rates add nothing; a Resource doesn't decay automatically. Use an Action's elapsed-time `onUpdate` for ongoing drains that need that time contract.

## Observe changes on the server

```lua
resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange)
	if change.resourceId == "Stamina" and change.currentNewValue <= change.minNewValue then
		print("Stamina exhausted")
	end
end)
```

Server changes include regeneration, so this listener can run on each regeneration step. A rate-only change doesn't fire the event. Property recomputation and Action payments install their affected Resource values before notifications, issuing each batch's net changes in Resource ID order. Ordinary successive calls and regeneration across several meters are separate updates.

## Read replicated values on a client

`ClientVisible` replicates Resource state and changes to every client, including other players. `ServerOnly` exposes nothing to clients, including the owner. Owner-only state needs a custom [replication domain](../replication/guide).

```lua
local resources: KRF.ResourcesView = actorView:GetResources()
local stamina: KRF.ResourceSnapshot? = resources:GetResource("Stamina")
```

The snapshot contains an estimate at the time of the query. KRF calculates client regeneration between server updates; it doesn't send a message for every server regeneration step. Read again every frame for a moving meter.

The client's `OnResourceChanged` reports changed state received from the server, such as a spend or a changed rate. It doesn't fire as the local estimate grows, and it doesn't replay changes that happened before the consumer attached. Subscribe, then read current state to initialize a display; keep the connection with that consumer's cleanup. Check `source` if a reaction should exclude a recovery baseline.

## Reuse the meter for cooldowns and charges

A cooldown can be a Resource with maximum 1 and regeneration rate `1 / seconds`. Require `{ minPercent = 1 }` and spend 1 on the Action. It starts full by default, so the ability is initially ready.

For three charges, use maximum 3, a cost of 1 and regeneration rate `1 / 5` to regain one charge every five seconds of advancement. The current value remains numeric between whole charges; the cost check decides whether a full charge is available.

See [Resources API](./api), [Actions](../actions/guide) and [Gather Qi](/tutorial/gather-qi).
