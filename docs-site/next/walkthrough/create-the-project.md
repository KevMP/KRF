---
title: Create the project
sidebar_label: 0. Create the project
sidebar_position: 1
description: Create a KRF project with create-krf, run it in Studio, and read through the starter code.
---

# Create the project

The walkthrough starts from the project that `create-krf` generates, so the first step is to create one and run it in Studio. The rest of this chapter goes through the starter code that later chapters change.

## Before you start

You need Node.js 22.12 or later and Roblox Studio. You don't have to install Rojo or KRF yourself, because the project's `npm install` step does that.

## Create a KRF project

```bash
npm create krf@latest my-game
```

The creator asks for a project mode and whether to add a GitHub Actions workflow. Choose Full as the mode, so the whole place, world included, is built from the files in your project. Either answer to the workflow question works for this walkthrough. Then install the project's dependencies:

```bash
cd my-game
npm install
```

`npm install` runs the project's setup script. If Rokit, the tool manager for Roblox tools, isn't on your machine yet, the script installs it first. It then uses Rokit to install Rojo, Wally and the other tools the project lists in `rokit.toml`, and uses Wally to download KRF. When the script has just installed Rokit, it prints `Rokit is installed. Open a new terminal so npm scripts can find the Roblox tools.` Open a new terminal in the project folder before you run anything else.

## Run it

```bash
npm run dev
```

`npm run dev` builds `my-game.rbxl` from the project's files, opens that place in Studio, and starts Rojo. To connect Studio to Rojo, open the Rojo plugin and click Connect. If Studio doesn't have the Rojo plugin, run `rojo plugin install` once from the project folder and restart Studio. Rojo copies every change you save in `src` into the open place, but only while `npm run dev` is running, so keep it open in its own terminal.

Press Play to check that the starter works. The label in the bottom-left corner shows `Energy 0/100`, and the number rises while you hold F and stops when you let go.

## How the starter is put together

The code is in `src`, with one folder for each place it runs. Code in `src/server` runs on the server, and code in `src/client` runs on each player's client. `src/shared` holds modules that both sides require, such as the list of Actions that clients may request.

`src/server/Startup.server.luau` starts KRF on the server. It passes every definition in the game to `Server.Init`, grouped by kind, and then calls `PlayerActors.Start`.

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

A definition is a module that describes one piece of gameplay, such as the Energy Resource in `src/server/Resources/Energy.luau`. Each kind of definition has its own folder, and the folder's `init.luau` returns every module inside it as one list. KRF calls that list a catalog, and `Server.Init` takes one catalog for each kind. Adding a definition therefore only takes a new file in the right folder. The project's generators, such as `npm run createResource`, create that file for you.

KRF keeps gameplay state on Actors. An Actor is usually a character Model, and its state is held by controllers attached to it, one each for its Resources, Tags, Properties and Actions. `src/server/PlayerActors.luau` registers each player's character as an Actor when it spawns and unregisters it when it's removed. Only server code can change an Actor's state. Client code reads a replicated copy of that state through an ActorView, and to start or stop an Action it sends the server a request, which the server accepts or rejects.

The starter has one ability, Focus, which runs while you hold F. These modules handle it, in the order they run.

1. `src/client/Controls/Keybinds.luau` binds F to an input named `AbilitySlot1`.
2. `src/client/Controls/Loadout.luau` routes that input to the Focus Action.
3. `src/client/ActionInputPolicies/Focus.luau` says Focus runs while the key is held, so pressing F sends the server a request to start Focus and releasing F sends a request to stop it.
4. `src/shared/ActionRequests/Focus.luau` tells both sides that clients may request Focus.
5. On the server, `src/server/Actions/Focus.luau` starts the Action and gives the Actor the Focused Tag while it runs.
6. `src/server/Tags/Focused.luau` adds 10 to the `EnergyRegen` Property, and the Energy Resource in `src/server/Resources/Energy.luau` regenerates at that rate.
7. The client's `src/client/EnergyDisplay.luau` reads Energy from the character's ActorView every frame and updates the label.

## Next

[Gather Qi](./gather-qi) turns the starter's Energy into Qi.
