---
title: Test the game
sidebar_label: 6. Test the game
sidebar_position: 7
description: Test how realm progression affects each character's Qi, then check code quality and server/client startup.
---

# Test the game

When one character advances, only that character's realm and Qi limit should change. Any Qi it has already gathered should stay at the same value. Let's put that behavior in a test.

If you're new to Jest, keep the [Jest Lua docs](https://jsdotlua.github.io/jest-lua/) handy for assertions, test hooks and other features you can use as your tests grow.

## Test progression with two characters

We'll register two Actors and advance one of them through its Cultivation Controller. Using the game's real Property and Resource controllers will let us check the resulting Qi values too.

Create `tests/Cultivation.spec.luau`:

```lua title="tests/Cultivation.spec.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local KRF = require(ReplicatedStorage.Packages.KRF)
local Cultivation = require(ServerScriptService.Game.Controllers.Cultivation)
local Properties = require(ServerScriptService.Game.Properties)
local Resources = require(ServerScriptService.Game.Resources)

local afterEach = JestGlobals.afterEach
local beforeEach = JestGlobals.beforeEach
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local models: { Model } = {}

local function registerCharacter(): KRF.Actor
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)

	return assert(KRF.ActorRuntime.RegisterActor(model))
end

describe("Cultivation", function()
	beforeEach(function()
		KRF.Server._ResetForTests()

		local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({
			properties = Properties,
			resources = Resources,
			controllers = { Cultivation },
		})

		expect(started).toBe(true)
		expect(failure).toBeNil()
	end)

	afterEach(function()
		for _, model: Model in models do
			local actor: KRF.Actor? = KRF.ActorRegistry.GetActorByModel(model)

			if actor ~= nil then
				KRF.ActorRuntime.UnregisterActor(actor, "TestCleanup")
			end

			model:Destroy()
		end

		table.clear(models)
		KRF.Server._ResetForTests()
	end)

	it("advances one character without refilling Qi or advancing another character", function()
		local first: KRF.Actor = registerCharacter()
		local second: KRF.Actor = registerCharacter()
		local firstCultivation: Cultivation.Cultivation = first:GetController("Cultivation") :: Cultivation.Cultivation
		local secondCultivation: Cultivation.Cultivation = second:GetController("Cultivation") :: Cultivation.Cultivation
		local firstResources: KRF.ResourceController = first:GetController("ResourceController") :: KRF.ResourceController
		local secondResources: KRF.ResourceController = second:GetController("ResourceController") :: KRF.ResourceController

		assert(firstResources:SetCurrent("Qi", 40))

		firstCultivation.Advance()

		expect(firstCultivation.GetRealm()).toBe(2)
		expect(firstResources:GetMax("Qi")).toBe(200)
		expect(firstResources:GetCurrent("Qi")).toBe(40)
		expect(secondCultivation.GetRealm()).toBe(1)
		expect(secondResources:GetMax("Qi")).toBe(100)
		expect(secondResources:GetCurrent("Qi")).toBe(0)
	end)
end)
```

The first character will start with 40 Qi, then advance to realm 2. Its limit should become 200 while its current value stays at 40. The second character should remain at realm 1 with its original Qi values.

The hooks will give each test fresh KRF registries and remove its Actors and Models afterward, even if an assertion fails. `_ResetForTests` is a test-only hook; keep it out of your game startup scripts.

Run the tests from your generated project folder:

```bash
npm test
```

The command will run the Jest specs in `tests` inside Roblox Studio and report any failures in the terminal.

It will also run the starter's `tests/Definitions.spec.luau`. That spec checks that IDs are unique within each Property, Tag, Resource and Action catalog, including definitions we've added to those catalogs. It doesn't exercise the abilities themselves.

## Check formatting and types

The starter also has a command for catching formatting, lint and type errors:

```bash
npm run check
```

This will run StyLua, Selene and luau-lsp without changing your files. If formatting is the problem, `npm run format` will fix it. If you included the GitHub Actions workflow when creating the project, it will run the checks and build the place on each push.

## Check server and client startup

Our progression test checks the server's state. To check whether the game starts correctly with players connected, run:

```bash
npm run test:studio
```

The smoke test will build a copy of the place and start a server with two clients. It will check that each character registers as an Actor and appears on its client as an ActorView. Startup failures will be reported in the command's output.

It won't press F, attempt a breakthrough or choose a sect. Keep using the earlier chapters' play steps to check those behaviors; the smoke test covers startup.

## Where to go from here

You can now gather Qi, advance through realms and choose a sect technique. If you'd like to build on the game, here are a few places to start:

- Add an aimed technique by declaring [Action request parameters](/Action/action-requests) and supplying them from an [input policy](/Action/action-input).
- Try a double tap, long hold or key sequence using [Action input](/Action/action-input).
- Keep a character's private progression visible only to its player with an [owner-only replication domain](/Networking/replication-domains).
- Send disposable cosmetic messages with [Hints](/Networking/hints).
- Let players change their controls with [Client controls](/Action/client-controls).

For more ways to use Qi, including cooldowns and charges, see [Resources](/reference/resources).
