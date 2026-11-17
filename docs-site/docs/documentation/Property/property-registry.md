# Property Registry

`PropertyRegistry` defines numeric Property IDs and their default base values for the server lifetime. Each Actor's `PropertyController` owns its assigned values and resolves active Tag modifiers.

## Declare Properties

Pass an array of definitions as `properties` in the [game configuration](../initializing-krf).

| Field | Contract |
| --- | --- |
| `id` | Unique, nonempty string |
| `defaultBaseValue` | Finite number |
| `autoAssign` | Optional boolean; defaults to `false` for game Properties |

`WalkSpeed = 16` and `JumpPower = 50` are built-in definitions with `autoAssign = true`. A game definition replaces either built-in's default. Omitted `autoAssign` inherits `true` for these two IDs; explicit `false` opts out. Repeating an ID in the game catalog fails validation.

Registration and assignment are separate. An unassigned registered Property returns `nil` from Actor queries and `false` from `HasProperty`. Auto-assignment, an Actor initial override, a first `SetBaseProperty` write, or a backing Resource creates Actor-local state. A Tag alone never assigns a Property.

Catalogs are validated before publication, including Tag, Resource and Action multiplier references. Definitions and query containers are owned, frozen copies. Source edits cannot change loaded defaults.

## Resource and Tag example

These modules form one complete catalog example. The loaders pass their definitions as `properties`, `resources` and `tags` during startup.

```lua title="Properties/MaxStamina.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local definition: KRF.PropertyDefinition = {
	id = "MaxStamina",
	defaultBaseValue = 100,
}
return definition
```

```lua title="Properties/StaminaRegen.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local definition: KRF.PropertyDefinition = {
	id = "StaminaRegen",
	defaultBaseValue = 12,
}
return definition
```

```lua title="Resources/Stamina.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local definition: KRF.ResourceDefinition = {
	id = "Stamina",
	max = { propertyName = "MaxStamina" },
	regen = { rate = { propertyName = "StaminaRegen" } },
	autoAssign = true,
	visibility = "ClientVisible",
}
return definition
```

```lua title="Tags/Rested.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local definition: KRF.TagDefinition = {
	id = "Rested",
	duplicateBehavior = "Ignore",
	visibility = "ServerOnly",
	properties = { MaxStamina = { add = 25 } },
}
return definition
```

After startup, register a spawned Model with its initial base override:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local function registerRestedActor(model: Model): KRF.Actor
	local actor, reason = KRF.ActorRuntime.RegisterActor(model, {
		properties = { MaxStamina = 150 },
	})
	assert(actor, reason)
	local tags = actor:GetController("TagController") :: KRF.TagController
	local added, tagReason = tags:AddTag("Rested")
	assert(added, tagReason)
	return actor
end
```

Resource construction sees a maximum of `150` and starts current Stamina at `150`. Adding `Rested` raises the resolved maximum to `175`; it does not refill the meter. Resource assignment preserves the override and seeds `StaminaRegen` from its registered default.

Initial values are installed silently before dependent controller factories run. Later base writes and Tag changes retain the [Property event contract](./property-runtime).

See the [PropertyRegistry API](/api/Property/property-registry) for infrastructure loading and lookup.
