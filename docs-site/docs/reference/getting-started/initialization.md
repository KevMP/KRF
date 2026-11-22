---
title: Initialization
---

# Initialization

Call `Server.Init` once before registering characters, and `Client.Init` once on each client before installing controls. Startup loads the game's definitions and prepares the networking contract for that session. Check each result before starting the code that depends on it.

## Install KRF in an existing project

Add KRF to `wally.toml` and run `wally install`.

```toml
[dependencies]
KRF = "kevmp/krf@0.2.0"
```

Mount Wally's `Packages` folder at `ReplicatedStorage.Packages` in the Rojo project. The examples below import KRF from there. For a project with the package and startup scripts already wired, follow the [Tutorial](/tutorial/).

## Supply server catalogs

Most server catalogs are arrays of definitions. A `create-krf` project collects them from modules in each definition folder. In a hand-written startup script, require those modules and pass their returned tables:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({
	properties = Properties,
	tags = Tags,
	resources = Resources,
	actions = Actions,
	controllers = Controllers,
	replicationDomains = ReplicationDomains,
	commands = Commands,
	hints = Hints,
	actionRequestSchemas = ActionRequests,
})

if not started then
	error(if failure then `{failure.system}: {failure.reason}` else "KRF startup failed")
end
```

The capitalized values are your game's catalog tables, usually returned by modules required above this call. Omit fields for catalogs the game doesn't need. Action entries are factory functions; other gameplay entries are definition tables. `actionRequestSchemas` is a map keyed by Action ID, rather than an array.

KRF validates catalog definitions and references during startup. A failure identifies the system and reason. Fix the definition and restart the session; each side permits one initialization attempt, including a failed attempt.

After success, register Models through [ActorRuntime](../actors/guide). KRF supplies its TagController, PropertyController, ResourceController and ActionController definitions. Game Controllers can depend on those keys without redefining them. Registration still has work to do, including constructing Controllers and capturing initial domain state, so check its result too.

## Initialize each client

Call `Client.Init` after the package and shared definition modules are available:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = require(ReplicatedStorage.Packages.KRF)

local started: boolean, failure: KRF.ClientStartupFailure? = KRF.Client.Init({
	actionRequestSchemas = ActionRequests,
	actionInputPolicies = ActionInputPolicies,
})

if not started then
	error(if failure then `{failure.system}: {failure.reason}` else "KRF client startup failed")
end
```

The client waits for the server's networking setup and installs its consumers. Successful startup enables ActorView discovery, input management and request APIs. It doesn't guarantee that a particular character's ActorView has already arrived; use [ActorViewRegistry](../actors/client-views).

Pass the same shared Action request schemas to both sides. Startup checks that the server provides compatible outer Action Commands; it does not compare every Action's parameter contract. A mismatched Action contract can instead reject Start. Keep both sides on the same shared module.

Client-only input policies define how a press becomes Start, Stop or Interrupt and aren't part of the shared wire declaration. Calling `Client.Init()` without a configuration still supports replication and InputRuntime, but doesn't install client Action requests.

## Keep definitions stable during play

Editing a source table after startup doesn't update the installed definition. Change an Actor's base stat through PropertyController or replace a client loadout's profile source. Those operations change live state through its owner.

Startup and session teardown own the framework's transports and built-in consumers. Don't replace those consumers or call registry preparation and publication methods from game code.

[Initialization API](./initialization-api) lists every startup field and result. [Create a KRF project](/tutorial/create-the-project) shows the generated startup scripts in use.
