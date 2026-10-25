---
sidebar_position: 2
---

# Initializing KRF

Initialize KRF once on the server and once on each client. Ordinary gameplay modules supply definitions or use controllers and views after initialization; they do not repeat setup.

A starter template with initialization already wired is not available yet. Use this page for manual integration. The system guides assume initialization is handled by your game's startup code.

## Game configuration

| Field | Supply |
| --- | --- |
| `controllers` | Game-specific controller factories and dependencies; KRF supplies its built-in controllers |
| `tags` | Status definitions and numeric modifiers |
| `resources` | Meter definitions, bounds, and regeneration |
| `actions` | Action factories with declarative requirements, costs, and behavior |
| `replicationDomains` | Game-owned state projections, event schemas, observers, and audiences |
| `commands` | [Command definitions](./Networking/commands) with target modes, optional schemas, explicit authorization, and handlers |
| `hints` | [Hint definitions](./Networking/hints) with direction, target, mode, bounded payload and explicit client-origin authorization/receive callbacks; ClientToServer sending and authorized server receipt |

Omitted catalogs are empty. Supply definitions here rather than calling registries' `Load` methods separately. KRF validates references across catalogs before publishing them.

## Server initialization

This minimal Script starts KRF with no game definitions. Add your catalogs to the configuration table.

```lua title="Startup.server.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = require(ReplicatedStorage.Packages.KRF.server)

local started, failure = Server.Init({})
if not started then
	local detail = if failure then failure.system .. ": " .. failure.reason else "Unknown startup failure"
	error("KRF startup failed: " .. detail)
end
```

After success, [register Actors](./Actor/actor-runtime). KRF attaches its built-in controllers and eligible game controllers in dependency order; catalog order breaks ties. Game controllers declare `dependsOn` for the controllers they use. See [Controller Registry](/api/Controllers/controller-registry) for the definition contract.

## Client initialization

Give one startup LocalScript ownership of `Client.Init()` and start your client systems after it succeeds. Consumer modules must not initialize KRF again. Initialization may yield while the framework transport replicates and the client completes protocol setup.

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

A successful return means the client has installed the server's protocol catalog, ActorView runtime, and [CommandRuntime](./Networking/commands) and received its readiness acknowledgement. Views become available as complete Actor baselines arrive; success does not guarantee that any view exists yet. See [ActorViews](./Networking/actor-views) for client state access and [Networking startup](./Networking/startup) for failure handling.

`Client.Init` accepts one attempt per client lifetime, including a failed attempt. Discovery and the handshake share a bounded deadline; handle a failure at your startup boundary rather than retrying initialization in a loop.

## Server startup guarantees

`Server.Init` does not yield. It validates catalogs, dependencies, Action references, domain schemas, event size bounds, and command definitions and schemas before publishing registries and transport. Domain `snapshot` and `observe` callbacks run later, when an Actor registers. Command authorization and handlers run only for received requests. If publication fails, KRF rolls back the catalogs and transport it created; pre-existing conflicting instances are preserved. The failure identifies its stage in `system` and its cause in `reason`.

A domain validation failure uses `system = "ReplicationDomain"`, a command catalog failure uses `system = "Command"`, and a Hint catalog failure uses `system = "Hint"`. Hint callbacks are not invoked during startup. Protocol preparation and transport failures use `system = "Networking"`. See [Networking startup](./Networking/startup) for diagnosis.

`Server.Init` accepts one attempt per server lifetime, including a failed attempt. Fix configuration and restart after failure. An empty domain catalog still starts transport. Action registration does not start Actions; `autoGrant` only establishes their initial availability on each Actor.

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
