---
title: Create the project
sidebar_label: 0. Create the project
sidebar_position: 1
description: Create the Ascension project with create-krf, run it in Studio, and learn what the starter does.
---

# Create the project

In this chapter you create the project, open it in Studio, and find your way around the code the walkthrough builds on.

## Before you start

You need Node.js 22.12 or later and Roblox Studio. The project installs everything else it needs, including Rojo and the KRF package.

## Create Ascension

```bash
npm create krf@latest ascension
```

:::note[Before create-krf is published]

`create-krf` isn't on npm yet. Until it is, build the two packages from the KRF repository with `npm pack --workspace krf-tools --workspace create-krf`, then pass both tarballs to `npx`:

```bash
npx --package ./krf-tools-0.1.0.tgz --package ./create-krf-0.1.0.tgz create-krf ascension
```

:::

The creator asks three questions. Choose the Full project mode, which keeps the whole place in your source files, and accept the others' defaults. Then install the project:

```bash
cd ascension
npm install
```

`npm install` also installs Rokit, the tool manager that provides Rojo and the other Roblox tools, if you don't have it yet, and then downloads KRF with Wally. If it says it installed Rokit, open a new terminal before running the next command.

## Run it

```bash
npm run dev
```

This builds `ascension.rbxl`, opens it in Studio, and starts Rojo so your edits sync into the open place. In Studio, open the Rojo plugin and click Connect. If you don't have the plugin, run `rojo plugin install` once from the project folder and restart Studio.

Press Play. A label in the bottom-left corner reads `Energy 0/100`. Hold F and it fills; let go and it stops. Leave `npm run dev` running while you work through the walkthrough.

## How the starter is put together

Game code lives in `src`, split by where it runs:

| Folder | Runs on | Holds |
| --- | --- | --- |
| `src/server` | Server | Startup, the definition catalogs, and code that registers Actors |
| `src/client` | Each client | Startup, controls and the Energy label |
| `src/shared` | Both | Modules both sides need, such as which Actions clients may request |

`src/server/Startup.server.luau` starts KRF. It hands `Server.Init` a catalog for each kind of definition, then starts registering players:

```lua title="src/server/Startup.server.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local ActionRequests = require(ReplicatedStorage.Shared.ActionRequests)
local Actions = require(script.Parent.Actions)
local PlayerActors = require(script.Parent.PlayerActors)
local Properties = require(script.Parent.Properties)
local Resources = require(script.Parent.Resources)
local Tags = require(script.Parent.Tags)

local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({
	properties = Properties,
	tags = Tags,
	resources = Resources,
	actions = Actions,
	actionRequestSchemas = ActionRequests,
})

if not started then
	local detail: string = if failure then `{failure.system}: {failure.reason}` else "unknown failure"

	error(`KRF server startup failed ({detail})`, 0)
end

PlayerActors.Start()
```

Each catalog is a folder with one module per definition, such as `src/server/Resources/Energy.luau`. Its `init.luau` collects every module in the folder, so adding a definition is just adding a file. The project's generators, such as `npm run createResource`, write that file for you.

KRF builds gameplay around Actors. An Actor is anything with gameplay state, usually a character Model. `src/server/PlayerActors.luau` registers each player's character as an Actor when it spawns and unregisters it when it's removed. Each Actor gets its own controllers that hold its state: its Resources, Tags, Properties and running Actions. Clients never touch that state directly. They read a copy through an ActorView, and they ask the server to do things.

Holding F shows how those pieces connect, and the next chapters change each step:

1. `src/client/Controls/Keybinds.luau` binds F to an input named `AbilitySlot1`.
2. `src/client/Controls/Loadout.luau` routes that input to the Focus Action.
3. `src/client/ActionInputPolicies/Focus.luau` says Focus runs while the key is held, so pressing F asks the server to start Focus and releasing it asks the server to stop.
4. `src/shared/ActionRequests/Focus.luau` tells both sides that clients may request Focus.
5. On the server, `src/server/Actions/Focus.luau` starts the Action and gives the Actor the Focused Tag while it runs.
6. `src/server/Tags/Focused.luau` adds 10 to the `EnergyRegen` Property, and the Energy Resource in `src/server/Resources/Energy.luau` regenerates at that rate.
7. The client's `src/client/EnergyDisplay.luau` reads Energy from the character's ActorView every frame.

The server makes every decision in that chain. The client only sends requests and draws what it's told.

## Next

[Gather Qi](./gather-qi) turns the starter's Energy into Qi.
