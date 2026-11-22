---
title: Test the game
sidebar_label: 6. Test the game
sidebar_position: 7
description: Unit-test the game's rules with Jest, check the code, and smoke-test it in Studio from the command line.
---

# Test the game

Every checkpoint so far meant pressing Play and watching. That doesn't scale, so this chapter adds the checks the project can run on its own.

## Unit tests

`npm test` runs Jest specs from `tests` inside Roblox Studio, without playing the game. The starter already has one, `tests/Definitions.spec.luau`, which checks that no two Properties, Tags, Resources or Actions share an ID. It now covers everything you've added.

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

None of these play the game. They don't hold F or break through, so a mistake in how an Action behaves still needs a playtest to find. What they catch quickly is a typo in a definition, a type error, or a rule that changed by accident.

## Where to go from here

The game uses most of what KRF offers today. It skipped these features.

- Actions can take start and stop parameters, such as an aim direction, declared in their request entry and supplied by the input policy.
- Inputs can recognize gestures such as a double tap or a long hold, and sequences such as X, Q, Z pressed in order. See [Action input](/Action/action-input).
- A replication domain with `audience = "Owner"` sends private state only to the Actor's own player.
- Hints carry disposable, cosmetic messages in either direction. See [Hints](/Networking/hints).
- `ClientControls.Apply` changes keybinds, routes and the controlled Actor together in one step. See [Client controls](/Action/client-controls).

[Resources](/reference/resources) covers the Resource system in full detail.
