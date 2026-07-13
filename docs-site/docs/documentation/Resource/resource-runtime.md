# Resource Runtime

`ResourceController` owns live resource state for one Actor: assignment, current values, resolved bounds, costs, and regeneration. The registry supplies definitions; the controller turns them into Actor-specific state.

## Assignment

Adding a resource resolves its state in this order:

1. Find the loaded definition.
2. Seed missing property-backed sources.
3. Resolve minimum, maximum, and optional regeneration rate.
4. Choose explicit override, definition initial value, or resolved maximum.
5. Clamp current value to the resolved bounds.
6. Store the resource and fire `OnResourceAdded`.

Definitions marked `autoAssign` run this flow when the controller is constructed. Assignment fails without partial resource state when the id, override, property source, or bounds are invalid.

## Mutation choices

| Intent | Method | Behavior at a bound |
| --- | --- | --- |
| Set an authoritative value | `SetCurrent` | Clamps to min and max. |
| Check a full cost | `CanSpend` | Never mutates. |
| Pay a full cost | `Spend` | Atomic; insufficient value fails unchanged. |
| Add value | `Restore` | Clamps at max. |
| Remove up to an amount | `Drain` | Clamps at min; partial drain succeeds. |

`Spend` measures available value above the resolved minimum, not above zero.

```lua
local resources = actor:GetController("ResourceController")

local paid, reason = resources:Spend("Resource.Stamina", 20)
if not paid then
	if reason == "InsufficientResourceValue" then
		return
	end

	warn(("Stamina spend failed: %s"):format(reason or "Unknown"))
	return
end

performDash(actor)
```

## Live property-backed state

Current resource value is not a property. Properties supply optional bounds and regeneration rates; the resource retains its own current value.

When a source property changes, KRF recomputes affected resources and clamps current value into new valid bounds. An invalid recompute preserves the last valid resource state.

| Property change | Resource event? |
| --- | --- |
| Minimum or maximum changes | Yes |
| Bounds clamp current value | Yes, in the same payload |
| Regeneration rate changes by itself | No |
| Unrelated property changes | No |

## Regeneration

Regeneration is measured in units per second and advances automatically in fixed 0.1-second steps while the Actor is enabled. It uses the latest resolved rate and clamps at maximum; a step that changes nothing fires no event.

## Design rules

- Use `Spend` for all-or-nothing gameplay costs and `Drain` for forced loss.
- Read resource current values from `ResourceController`, never `PropertyController`.
- Attach `ResourceController` after `PropertyController` when using live sources.
- Subscribe to `OnResourceChanged` when another runtime system needs current value or bound changes.

## API reference

- [`ResourceController`](/api/Resource/resource-controller)
- [`ResourceRegistry`](/api/Resource/resource-registry)
- [`PropertyController`](/api/Property/property-controller)
