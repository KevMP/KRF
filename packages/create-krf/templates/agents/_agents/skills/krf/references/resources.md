# Resources

A Resource is a value an Actor spends and regains, such as Health, Mana, Stamina, ability charges or a cooldown. Each Actor has its own current value, kept between a minimum and a maximum, with optional regeneration. The server changes it, and clients can read it.

## Define a meter

```bash
npm run createResource -- --name Stamina --max MaxStamina --regen StaminaRegen --visibility ClientVisible --yes --json
```

- **Bounds:** `--max` and `--min` take a number or a Property ID. The defaults are 100 and 0. A Property ID makes the bound follow that Actor's resolved stat, so a Tag that raises MaxStamina raises the meter. Generate the Property first. See [properties.md](properties.md).
- **Regeneration:** `--regen` is the amount per second, as a number or a Property ID. Leave it off for a meter that never refills on its own. A Resource never decays by itself.
- **Starting value:** a new Resource starts full. Pass `--initial 0` for a meter players fill themselves.
- **Visibility:** `ClientVisible` sends the value to every client, including other players. `ServerOnly` sends it to no client, not even its owner. Choose `ClientVisible` whenever the player's UI shows it.
- **Assignment:** the generator gives the Resource to every Actor. Pass `--no-auto-assign` for one an Actor has to earn.

For every flag and how to read the result, see [generators.md](generators.md#createresource).

## Give it to an Actor later

For an earned Resource, assign it when the Actor unlocks it:

```lua
local resources = actor:GetController("ResourceController") :: KRF.ResourceController
local added: boolean, reason: string? = resources:AddResource("Mana", 0)
```

The second argument overrides the starting value. A Resource stays until the Actor ends, and there's no way to remove it. Control what the player can do with it through Action grants or Tags instead.

## Charge Actions through their definition

An Action's price belongs on the Action, not in code that calls `Spend`:

```bash
npm run createAction -- --name Fireball --cost Mana=20 --requirement Mana:minPercent=0.5 --requestable --yes --json
```

KRF checks requirements and costs before the Action starts, and spends only if it accepts the request. Costs across several Resources are paid together. Nothing is refunded when the Action ends or is interrupted. Calling `Spend` yourself before a request can charge for a request the server then rejects. See [actions.md](actions.md).

## Change it from gameplay

Use ResourceController for changes that aren't an Action's price, such as damage, a pickup or a trap:

| Method | What it does |
| --- | --- |
| `Spend(id, amount)` | Removes exactly `amount`, or nothing if there isn't enough |
| `CanSpend(id, amount)` | Checks a `Spend` without changing anything |
| `Drain(id, amount)` | Removes up to `amount`, stopping at the minimum. Use it for damage. |
| `Restore(id, amount)` | Adds up to `amount`, stopping at the maximum. Use it for healing. |
| `SetCurrent(id, value)` | Sets the value, clamped to the bounds |

Each returns `(boolean, string?)`. Check the result when it matters.

## Build cooldowns and charges from Resources

A cooldown is a Resource, not a timer:

```bash
npm run createResource -- --name FireballCooldown --max 1 --regen 0.25 --visibility ClientVisible --yes --json
```

Then give the Action `--requirement FireballCooldown:minPercent=1 --cost FireballCooldown=1`. The Resource starts full, so the ability is ready at first. Each use empties it, and it refills in `1 / regen` seconds, which is four seconds here.

For charges, raise the maximum: a maximum of 3 with a cost of 1 and `--regen 0.2` holds three charges and regains one every five seconds. The value is fractional between charges, and the cost check decides whether a whole charge is ready.

## React to changes on the server

```lua
resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange): ()
	if change.resourceId == "Health" and change.currentNewValue <= change.minNewValue then
		defeat(actor)
	end
end)
```

This fires on every regeneration step too, so keep the listener cheap and filter by `resourceId`.

## Show it on the client

Clients read a `ClientVisible` Resource through the Actor's ResourcesView. Between server updates the client estimates regeneration itself, so a moving bar should read the value every frame. See [client-views.md](client-views.md).

## Exact APIs

- [Resources guide](docs/resources/guide.md) and [Resources API](docs/resources/api.md): definition fields, method failures, change records and regeneration timing.
- [Actions API](docs/actions/api.md): requirement thresholds and percentage costs.

## Related references

- [properties.md](properties.md) for stats that set a Resource's bounds or regeneration.
- [actions.md](actions.md) for Action requirements and costs.
- [client-views.md](client-views.md) for showing a meter in the client UI.
