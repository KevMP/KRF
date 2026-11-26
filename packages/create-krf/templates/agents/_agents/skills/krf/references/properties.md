# Properties

A Property is a number on an Actor, such as Defense, MaxHealth or WalkSpeed. Each one keeps a base value and a resolved value. The resolved value is the base value plus every active Tag modifier, and it's the value gameplay reads. A buff or debuff never touches the base value, so when it ends there's nothing to put back.

## Define a stat

```bash
npm run createProperty -- --name Defense --default 10 --auto-assign --yes --json
```

`--auto-assign` gives the Property to every Actor at its default. Leave it off for a stat only some Actors have. Then assign it when you register the Actor with `properties = { Defense = 25 }`, or with the first `SetBaseProperty` call. An unassigned Property reads as `nil`.

KRF already defines `WalkSpeed` (16) and `JumpPower` (50) for every Actor.

For every flag and how to read the result, see [generators.md](generators.md#createproperty).

## Read the resolved value

```lua
local properties = actor:GetController("PropertyController") :: KRF.PropertyController
local defense: number? = properties:GetResolvedProperty("Defense")
```

Gameplay reads `GetResolvedProperty`, which includes every active Tag modifier. `GetBaseProperty` is the underlying stat without them.

## Change it the right way

Use `SetBaseProperty` only for lasting changes, such as a level-up or equipping gear:

```lua
local changed: boolean, reason: string? = properties:SetBaseProperty("Defense", 20)
```

For a temporary change, add a Tag with a modifier. Never apply a buff by writing a new base value and remembering to undo it later. See [tags.md](tags.md) for modifiers and how they combine.

## Apply movement Properties yourself

A Property is only a number, and KRF never writes Humanoid fields. A slow that halves `WalkSpeed` changes the resolved value and nothing else. For it to move the character, the game must apply that value to the Humanoid. Check whether the game already does. If it doesn't, connect to `OnResolvedPropertyChanged` and set `Humanoid.WalkSpeed` from the resolved value.

## React to changes

- `OnResolvedPropertyChanged` fires when the value gameplay reads changes. Most consumers want this one.
- `OnBasePropertyChanged` fires when the underlying stat changes.
- `OnPropertyChanged` fires once with both transitions in a single record.

Setting the value it already has fires nothing.

## Clients can't read Properties

Properties don't replicate. A client sees a Property only through a Resource whose bounds or regeneration read it, or through a replication domain the game publishes. See [resources.md](resources.md) and [replication.md](replication.md).

## Exact APIs

- [Properties guide](docs/properties/guide.md) and [Properties API](docs/properties/api.md): assignment, the resolution formula, events and failure reasons.

## Related references

- [tags.md](tags.md) for the modifiers that change resolved values.
- [resources.md](resources.md) for Resources whose bounds or regeneration read a Property.
- [replication.md](replication.md) for showing a Property to clients.
