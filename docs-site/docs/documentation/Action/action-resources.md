---
sidebar_position: 6
---

# Action Resources

Use `resourceRequirements` for start-time meter conditions and `costs` for atomic upfront payment. `ResourceController` owns assignment, current values, resolved bounds, and regeneration; Actions reference that existing state.

## Requirements versus payment

| Intent | Declare | Result |
| --- | --- | --- |
| Start only below half Health | `resourceRequirements = { Health = { maxPercent = 0.5 } }` | Checks the meter; spends nothing. |
| Pay 15 Stamina | `costs = { Stamina = 15 }` | Affordability check and full payment on acceptance. No duplicate requirement is needed just to afford this cost. |
| Start with at least 30 Mana but pay 10 | Requirements `{ min = 30 }` and cost `10` for Mana | Both checks use pre-spend state. |

These are definition fragments; use your registered Resource ids. Register Resources alongside Actions, then assign them to the Actor with `autoAssign` or `ResourceController:AddResource`. Requests never assign missing Resources or create multiplier Properties, even when a multiplier would make a cost free.

## Thresholds

Requirements may combine inclusive `min`, `max`, `minPercent`, and `maxPercent` checks. Every supplied check must pass. Percentages are fractions from `0` to `1` of the usable range:

```text
normalized current = (current - resolved min) / (resolved max - resolved min)
```

For min `20`, max `120`, and current `70`, normalized current is `0.5`. Percentage requirements need a positive range; absolute thresholds do not. Requirements are checked at start and do not automatically cancel a running Action when the meter later changes.

## Fixed, percentage, and Property-scaled costs

```lua
-- Alternative costs inside a definition; choose one for this Resource.
costs = { ["Resource.Stamina"] = 15 },
costs = { ["Resource.Stamina"] = { amount = 15 } },
costs = { ["Resource.Stamina"] = { percent = 0.25 } },
costs = {
	["Resource.Stamina"] = { amount = 15, multiplierProperty = "StaminaCostMultiplier" },
},
```

A numeric cost is fixed shorthand. A structured cost specifies exactly one positive finite `amount` or `percent`. Cost percentages may exceed `1`; they measure capacity, not the current meter:

```text
base percentage cost = (resolved max - resolved min) * percent
effective cost = base cost * resolved multiplier Property  (when supplied)
```

A `0.25` cost against min `20` and max `120` is `25`, regardless of current value. Affordability measures available value above the resolved minimum. Percentage costs allow a zero range and produce a zero base cost.

`multiplierProperty` reads the Actor's resolved Property, including existing Tag modifiers. It must exist and be finite and non-negative; `0` makes the effective cost free. Create a custom multiplier with `PropertyController:SetBaseProperty` before requesting the Action. The effective cost must be finite and non-negative.

See [ActionResourceRequirement](/api/Action/action-types#action-resource-requirement) and [ActionResourceCost](/api/Action/action-types#action-resource-cost) for exact field constraints.

## Atomic upfront payment

KRF checks requirements and affordability before calling the request factory. After `onCanStart` and lock interruption decisions, it builds a fresh final plan from current authoritative state. Every declared cost must be affordable before any is paid.

Acceptance commits the plan with preemption, locks, Tags, and derived state before consumer callbacks. Rejection commits none of those incoming effects and consumes no sequence id. Explicit mutations performed by game decision callbacks remain committed; they are not rolled back. Keep decisions observational and put acceptance-time payment in `costs`, rather than calling `Spend` inside `onCanStart`.

The final plan is fixed before preempted owners' Tags are removed or incoming Tags are applied. Same-transaction Tag/Property changes do not re-price the incoming Action or rescue a failing requirement. For example, if preemption removes a Mana capacity buff, a percentage cost still uses the capacity seen by the final plan.

Final valid bounds clamp the already-paid current value. Invalid derived bounds preserve the last valid Resource min/max/regen state; they do not undo the accepted Action or its payment. [Advanced Ordering & Reentrancy](./action-ordering) owns the full commit and notification contract.

**There are no automatic refunds.** End, Interrupt, preemption, start/update failure, and controller destruction retain payment. Any refund is explicit game policy using `ResourceController:Restore`.

## Cooldowns and charges are Resources

A cooldown is a readiness meter: require full value, spend its capacity, and regenerate. Charges are a pool: require at least one, spend one, and restore through regeneration or game outcomes. Several Actions may share a Resource for a shared cooldown or charge pool.

Neither meter controls Action lifetime. An instant Action can End while its cooldown recharges. A channel can remain active after its startup charge is spent. See the small [cooldown](./action-patterns#cooldown) and [charge](./action-patterns#charges) recipes.

## Ongoing or outcome-dependent behavior

Use the Actor's [ResourceController](/api/Resource/resource-controller) directly for channel drains, per-tick sprint payment, rewards, hit-dependent spending, or explicit refunds. Static `costs` are paid once, not each update.

Choose `Spend` for a full payment that must succeed before work; choose `Drain` for forced loss that may clamp at the minimum. Check failures and, after a call that can invoke listeners, recheck Action activity before continuing. The [sprint recipe](./action-patterns#sprint) shows this boundary.

Next: [Locks & Preemption](./action-locks). Related: [Resource Runtime](../Resource/resource-runtime), [Property Runtime](../Property/property-runtime), [request rejection reasons](/api/Action/action-controller#request-action).
