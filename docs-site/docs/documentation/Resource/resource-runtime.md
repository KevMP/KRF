# Resource Runtime

KRF treats a resource as actor-scoped runtime state backed by a static resource definition.

Use resources when your game needs meters such as stamina, mana, energy, focus, rage, breath, heat, or other values that belong to one live actor.

## What this is

A resource is a current actor-scoped meter in KRF.

Each live resource has:

* a current value
* a resolved minimum and maximum
* an optional regeneration rate

The definition for that resource is loaded through `ResourceRegistry`, but the live value belongs to one actor at runtime.

Two actors may both use `Resource.Stamina`, but each actor owns its own current value, resolved bounds, and regeneration behavior.

## What resources own

Resource Runtime owns:

* current resource values on live actors
* resolved minimum and maximum bounds for those values
* optional regeneration for resource types that define it
* actor-scoped resource state instead of global shared meter state

## What resources do not own

Resource Runtime does not own:

* loading the resource catalog
* actor registration
* property values themselves
* combat meaning, UI meaning, or progression meaning
* health as an automatic built-in resource

KRF still owns numeric properties through Property Runtime. Resource Runtime reads property-backed limits and regen from that system, but current resource values stay separate from properties.

## Resource definitions and live state

`ResourceRegistry` defines what a resource means.

That definition may include:

* id
* visibility
* minimum and maximum numeric sources
* optional initial value
* optional automatic assignment
* optional regeneration metadata

After that catalog is loaded, live resource state is where KRF:

* assign resources to actors
* resolve actor-specific defaults
* seed missing property-backed base values
* clamp current value within resolved bounds
* spend, restore, drain, or regenerate current value

## Property-backed resources

Resource definitions may use:

* static numeric sources through `value`
* property-backed numeric sources through `propertyName` and `defaultBaseValue`

This keeps resource definitions connected to Property Runtime without turning resource state into another property table.

A property-backed resource still owns its own current value. Properties only supply the numbers that resource state resolves against.

## Common mistakes

* Treating a resource definition as if it were already live state on every actor.
* Treating current resource values as properties instead of actor-scoped runtime state.
* Using a property-backed source when the value is really just static authored data.

## Related concepts

Read [Resource Registry](./resource-registry) for the startup catalog and definition rules.

Read [Property Runtime](../Property/property-runtime) for the numeric property surface used by property-backed limits and regeneration.

Read [Actor Runtime](../Actor/actor-runtime) for the actor lifecycle resources will eventually live inside.
