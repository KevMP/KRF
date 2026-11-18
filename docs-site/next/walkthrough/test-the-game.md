---
title: Test the game
sidebar_label: 11. Test the game
sidebar_position: 12
description: Unit-test the game's rules with Jest, check the code, and smoke-test it in Studio from the command line.
---

# Test the game

Every checkpoint so far meant pressing Play and watching. That doesn't scale, so this chapter adds the checks the project can run on its own.

## Unit tests

`npm test` runs Jest specs from `tests` inside Roblox Studio, without playing the game. The starter already has one, `tests/Definitions.spec.luau`, which checks that every Property, Tag, Resource and Action ID is unique. It now covers everything you've added.

Rules that are plain functions are the easiest to test. That's one reason the realm numbers live in `src/shared/Realms.luau` instead of inside the Cultivation Controller. Add `tests/Realms.spec.luau`:

```lua title="tests/Realms.spec.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Realms = require(ReplicatedStorage.Shared.Realms)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Realms", function()
	it("doubles maximum Qi with each realm", function()
		expect(Realms.MaxQi(1)).toBe(100)
		expect(Realms.MaxQi(2)).toBe(200)
		expect(Realms.MaxQi(#Realms.NAMES)).toBe(800)
	end)
end)
```

```bash
npm test
```

Jest prints each spec, and the command fails if any test fails.

## Check the code

```bash
npm run check
```

This checks formatting with StyLua, lints with Selene and type-checks everything in `src` with luau-lsp, without changing any files. `npm run format` fixes formatting. If you created the project with a GitHub Actions workflow, it runs `npm run check` and builds the place on every push.

## Smoke-test in Studio

```bash
npm run test:studio
```

This builds a copy of the place, plays it in Studio with a server and two clients, and confirms that KRF starts and every player's character becomes an Actor. A broken definition fails here with the reason, the same way the game would fail to start.

None of these play the game. They don't press F or fire a bolt, so a mistake in how a technique behaves still needs a playtest to find. What they do catch quickly is a typo in a definition, a type error, or a rule that changed by accident.

## Where to go from here

The game now uses most of what KRF offers. A few things it didn't need are worth knowing about:

- Input sequences recognize combos such as X, Q, Z pressed in order, and custom recognizers let you write your own. See [Action input](/Action/action-input).
- The `Toggle` input policy starts an Action on one press and stops it on the next.
- A replication domain with `audience = "Owner"` sends private state only to the Actor's own player.
- Client-to-server Hints carry cosmetic data from clients, such as where a player is looking.
- `ClientControls.Apply` changes keybinds, routes and the controlled Actor together in one step, for example when a player mounts a creature. See [Client controls](/Action/client-controls).

The [Resources](/reference/resources) reference covers the Resource system in full detail.
