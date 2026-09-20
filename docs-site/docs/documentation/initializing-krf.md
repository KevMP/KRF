---
sidebar_position: 2
---

# Initializing KRF

KRF has separate server and client setup. The server flow below loads the shared definitions used to create Actors.

Server startup is the boundary between configuration and live Actor state. Your game supplies controller, tag, and resource definitions once. KRF validates those catalogs together, then uses the loaded controller factories to attach the same eligible controller set to every new Actor.

| Catalog | What it determines |
| --- | --- |
| Controllers | Which controller factories are available to Actors, and their attachment order |
| Tags | Which statuses an Actor's `TagController` can apply |
| Resources | Which meters an Actor's `ResourceController` can assign |

## Server initialization

Compose KRF and game controller definitions in one array. Dependency order decides which factory runs first; catalog order breaks ties between unrelated controllers.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local Server = require(KRF.server)
local PropertyController = require(KRF.server.Property.PropertyController)
local TagController = require(KRF.server.Tags.TagController)
local ResourceController = require(KRF.server.Resource.ResourceController)
local ControllerTypes = require(KRF.server.Controller.types)
local GameCombatController = require(script.Parent.GameCombatController)

local controllers: { ControllerTypes.ControllerDef } = {
	{ key = "PropertyController", factory = PropertyController.new },
	{ key = "TagController", factory = TagController.new, dependsOn = { "PropertyController" } },
	{ key = "ResourceController", factory = ResourceController.new, dependsOn = { "PropertyController" } },
	{
		key = "Game.CombatController",
		dependsOn = { "TagController", "ResourceController" },
		factory = GameCombatController.new,
	},
}

local started, failure = Server.Init({
	controllers = controllers,
	tags = {
		{
			id = "Status.Rooted",
			duplicateBehavior = "Refresh",
			visibility = "ServerOnly",
			defaultDuration = 2,
		},
	},
	resources = {
		{
			id = "Resource.Stamina",
			max = { value = 100 },
			visibility = "ServerOnly",
			autoAssign = true,
		},
	},
})
if not started then
	local detail = if failure then ("%s: %s"):format(failure.system, failure.reason) else "Unknown startup failure"
	error("KRF startup failed: " .. detail)
end
```

The example assumes `GameCombatController` is a controller module beside your startup script. Replace it, the tag, and the resource with your game's definitions. Omitted catalogs load as empty.

## Client initialization

TODO

## Server startup result

`Server.Init` validates every catalog before publishing them. An invalid definition, missing dependency, or controller cycle leaves all three registries unpublished. The failure identifies the catalog in `system` and the validation error in `reason`.

`Server.Init` accepts one attempt per server lifetime, including a failed attempt. Fix startup configuration and restart the server after a failure. After a successful call, [Actor Runtime](./Actor/actor-runtime) can register Actors against the loaded controller catalog.

## Related

- [Server API](/api/Server/)
- [Controller Registry](/api/Controllers/controller-registry)
- [Tag Registry](./Tags/tag-registry)
- [Resource Registry](./Resource/resource-registry)
