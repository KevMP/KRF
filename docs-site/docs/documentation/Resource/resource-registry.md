# Resource Registry

`ResourceRegistry` is KRF's startup catalog for resource definitions.

Resources give KRF a shared definition for actor-scoped meters such as stamina, mana, energy, rage, focus, breath, heat, or other game-defined values.

A resource definition is not a live resource value on an actor. It is the static definition KRF uses later when a `ResourceController` adds that resource to an actor.

## What this is

`ResourceRegistry` loads resource definitions once during startup.

Each definition describes:

* a unique resource id
* visibility
* a minimum source
* a maximum source
* an optional initial value
* optional automatic assignment
* optional regeneration metadata

Numeric sources may be:

* static, through `value`
* property-backed, through `propertyName` and `defaultBaseValue`

## What this owns

`ResourceRegistry` owns:

* validating resource definition shape
* rejecting duplicate ids
* rejecting invalid numeric source metadata
* freezing the loaded catalog for the lifetime of the server
* applying actor-independent defaults such as omitted `min` and omitted `autoAssign`

## What this does not own

`ResourceRegistry` does not own:

* current resource values on actors
* assigning resources to actors
* spending, restoring, draining, or regenerating current values
* seeding actor properties for property-backed sources
* resolving actor-specific defaults such as a missing `initialValue` from a live actor's current max

Those runtime responsibilities belong to `ResourceController`.

## Loading a resource catalog

Games define their resource catalog in data and load it once during startup.

Load rules:

* load happens once during startup
* load is all or nothing
* invalid catalogs do not partially register
* a second successful load is not supported
* successful load freezes the catalog for the lifetime of the server

## Numeric source semantics

KRF supports two numeric source shapes.

### Static source

A static source uses `value`.

Use it when the definition can supply the number directly, such as a fixed minimum of `0` or a fixed maximum of `100`.

### Property-backed source

A property-backed source uses `propertyName` and `defaultBaseValue`.

Use it when the number should come from `PropertyController` at runtime. The default base value exists so KRF can seed a missing property safely when the resource is assigned to an actor.

A source must use exactly one of `value` or `propertyName`.

## Common mistakes

* Treating a registered resource definition as an active resource on an actor. `ResourceRegistry` defines the catalog. `ResourceController` owns live current values.
* Expecting a missing `autoAssign` to add the resource to every actor. Omission means `false`.
* Expecting a missing `initialValue` to resolve during registry load. That default depends on the live actor's current max when the resource is assigned.
* Putting property seeding logic into startup code. Property-backed sources are seeded when the resource is added to an actor, not when the registry loads.

## Example catalog

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local ResourceTypes = require(KRF.server.Resource.types)

local ResourceDefinitions: { ResourceTypes.ResourceDefinition } = {
	{
		id = "Resource.Stamina",
		min = {
			value = 0,
		},
		max = {
			propertyName = "MaxStamina",
			defaultBaseValue = 100,
		},
		visibility = "ClientVisible",
		autoAssign = true,
		regen = {
			rate = {
				propertyName = "StaminaRegen",
				defaultBaseValue = 12,
			},
		},
	},
	{
		id = "Resource.Guard",
		max = {
			value = 50,
		},
		visibility = "ServerOnly",
	},
}

local loaded: boolean, reason: string? = ResourceRegistry.Load(ResourceDefinitions)

if not loaded then
	error(reason)
end
```

## Related concepts

Read [Resource Runtime](./resource-runtime) for the live per-actor runtime surface that owns current resource values.

Read [Property Runtime](../Property/property-runtime) for the actor-side numeric property surface that property-backed resource sources resolve through.
