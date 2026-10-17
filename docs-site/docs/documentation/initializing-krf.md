---
sidebar_position: 2
---

# Initializing KRF

KRF has separate server and client setup. Initialize the server once with your game's definitions, then initialize each client before continuing client startup.

Server startup is the boundary between configuration and live Actor state. Your game supplies controller, Tag, Resource, Action, and replication domain definitions once. KRF validates those catalogs together, then uses the loaded controller factories to attach the same eligible controller set to every new Actor.

| Catalog | What it determines |
| --- | --- |
| Controllers | Which controller factories are available to Actors, and their attachment order |
| Tags | Which statuses an Actor's `TagController` can apply |
| Resources | Which meters an Actor's `ResourceController` can assign |
| Actions | Static Action metadata, including Tag preconditions, Resource costs, and interruption permissions |
| Replication domains | Approved state projections, semantic event schemas, observation adapters, and audiences |

## Server initialization

Pass your game's controller definitions to `Server.Init`. KRF adds its own controllers before validating the combined catalog. Dependencies decide attachment order; catalog order breaks ties between unrelated controllers.

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local Server = require(KRF.server)
local ControllerTypes = require(KRF.server.Controller.types)
local GameCombatController = require(script.Parent.GameCombatController)

local controllers: { ControllerTypes.ControllerDef } = {
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

The example assumes `GameCombatController` is a controller module beside your startup script. Replace it, the tag, and the resource with your game's definitions. Omitted game catalogs load as empty; KRF's built-in controllers still load.

## Client initialization

Call `Client.Init()` from a LocalScript, such as your startup script in `StarterPlayerScripts`. It may yield while the framework transport replicates and the client completes protocol setup.

```lua title="Startup.client.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packages = ReplicatedStorage:WaitForChild("Packages")
packages:WaitForChild("KRF"):WaitForChild("client")
local Client = require(ReplicatedStorage.Packages.KRF.client)

local started: boolean, failure: Client.StartupFailure? = Client.Init()
if not started then
	local detail: string = if failure then failure.system .. ": " .. failure.reason else "Unknown startup failure"
	error("KRF client startup failed: " .. detail)
end

-- Continue your game's client startup here.
```

A successful return means the client has installed the server's protocol catalog and ActorView runtime and received its readiness acknowledgement. Views become available as complete Actor baselines arrive; success does not guarantee that any view exists yet. See [ActorViews](./Networking/actor-views) for client state access and [Networking startup](./Networking/startup) for failure handling.

`Client.Init` accepts one attempt per client lifetime, including a failed attempt. Discovery and the handshake share a bounded deadline; handle a failure at your startup boundary rather than retrying initialization in a loop.

## Server startup result

`Server.Init` does not yield. It prepares the catalogs and protocol, then publishes the registries and framework transport as one startup operation. An invalid definition, missing reference or dependency, or controller cycle leaves the registries unpublished. If publication fails after it begins, KRF rolls back the catalogs and transport it created. The failure identifies the responsible system in `system` and the error in `reason`.

Supply the optional `actions` array to load the [Action Registry](./Action/action-registry). Its Tag, Resource, and Action references resolve against the complete prepared registries. Omitting `actions` publishes an empty Action registry. Each registered Actor receives an [`ActionController`](./Action/action-grants); `autoGrant` definitions form its initial grant baseline without starting Actions.

Supply the optional `replicationDomains` array to register [replication domains](./Networking/replication-domains). This catalog is independent from controller definitions. Startup compiles its state and event schemas, defaults audiences to `All`, and prepares a shared protocol catalog without invoking `snapshot` or `observe`. A domain validation failure uses `system = "ReplicationDomain"`; a protocol preparation or transport failure uses `system = "Networking"`. An empty domain catalog still starts the framework transport.

`Server.Init` accepts one attempt per server lifetime, including a failed attempt. Fix startup configuration and restart the server after a failure. After a successful call, [Actor Runtime](./Actor/actor-runtime) can register Actors against the loaded controller catalog.

## Related

- [Server API](/api/Server/)
- [Client API](/api/Client/)
- [Networking startup](./Networking/startup)
- [Controller Registry](/api/Controllers/controller-registry)
- [Tag Registry](./Tags/tag-registry)
- [Resource Registry](./Resource/resource-registry)
- [Action Registry](./Action/action-registry)
- [Action grants](./Action/action-grants)
- [Replication domains](./Networking/replication-domains)
