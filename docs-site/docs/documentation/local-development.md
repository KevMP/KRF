---
sidebar_position: 2.4
description: Build, sync, check and test a create-krf project locally with its npm scripts.
---

# Local Development

Projects created with `create-krf` develop, check and test through npm scripts. The scripts run the Roblox tools pinned in the project's `rokit.toml` and the `krf-tools` version in its `devDependencies`; nothing needs a global install, a published experience, Team Create or cloud credentials.

| Script | Does |
| --- | --- |
| `npm run dev` | Builds the place, opens it in Roblox Studio and serves the project with Rojo |
| `npm run build` | Builds the place file with Rojo |
| `npm run check` | Checks formatting with StyLua, lints with Selene and type checks `src` with luau-lsp; never changes files |
| `npm run format` | Formats `src` and `tests` with StyLua |
| `npm test` | Runs the Jest specs in `tests` inside Roblox Studio |
| `npm run test:studio` | Plays the game in Roblox Studio with a server and clients and checks that KRF starts |

`npm run dev`, `npm test` and `npm run test:studio` need Roblox Studio, which runs on Windows and macOS. `npm run check` and `npm run build` run anywhere the Rokit tools do, including CI.

## Develop in Studio

```bash
npm run dev
```

1. Builds the place. A Full project builds `<name>.rbxl` from `default.project.json`; a build failure stops here.
2. Starts `rojo serve default.project.json` and waits until it reports its port.
3. Opens the place in Roblox Studio.
4. Stays attached while Rojo serves your changes. In Studio, open the Rojo plugin, connect to the reported address, then press Play. If Studio has no Rojo plugin, run `rojo plugin install`.

Ctrl+C stops the Rojo server this command started. Studio stays open with your session.

When Studio already has the place open, `npm run dev` neither rebuilds nor reopens it; it only starts Rojo.

### Hybrid projects

In a Hybrid project, `<name>.rbxl` holds the world you build in Studio and Rojo serves only `src` and `Packages`. The first `npm run dev` creates that place from `start-place.project.json`; later runs open it as it is and never rebuild it. `npm run build` writes `build/<name>.rbxl` instead, so it never touches your place.

### Options

Pass options after `--`, for example `npm run dev -- --no-open`.

| Option | Meaning |
| --- | --- |
| `--no-open` | Serve without opening Studio |
| `--port <port>` | Serve on this port instead of 34872. A busy port is reported, not replaced |
| `--place <file>` | Hybrid only: the place that holds your world |
| `--studio-path <path>` | The Roblox Studio executable, when it is not found automatically |

## Check and format

`npm run check` reports problems without changing files, and fails if formatting, linting or type checking fails. `npm run format` is the only script that rewrites files. The generated CI workflow runs `npm run check` and `npm run build`.

## Unit tests

`npm test` builds a test place from the game's Rojo project plus `tests` and the Wally dev dependencies, then runs Jest in Roblox Studio and prints Jest's report. Specs are `tests/**/*.spec.luau` and import Jest's functions from `ReplicatedStorage.DevPackages.JestGlobals`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

JestGlobals.describe("Energy", function()
	JestGlobals.it("starts empty", function()
		JestGlobals.expect(0).toBe(0)
	end)
end)
```

`tests/jest.config.luau` selects the specs. Jest and JestGlobals are Wally dev dependencies, so they are installed in `DevPackages` and never ship in the game's place.

## Studio smoke test

`npm run test:studio` adds a server script and a client script to a copy of the game's place and plays it in Studio with one server and two clients. It passes when the server sees every player's character registered as an Actor and every client sees its own character's ActorView. A failure names the step that failed and the first server error, such as a rejected `Server.Init`.

| Option | Meaning |
| --- | --- |
| `--clients <count>` | How many clients join, from 1 to 8; default 2 |
| `--timeout <seconds>` | How long Studio may run; default 300 |
| `--studio-path <path>` | The Roblox Studio executable |

`npm test` takes `--timeout` and `--studio-path` too.

## Results

Each test run keeps its place and Studio output in `build/krf/<run>/`, which the project ignores. Only one Studio test runs per project at a time.

| Exit code | Meaning |
| --- | --- |
| `0` | Passed |
| `1` | Tests failed, or a tool or Studio could not be found |
| `2` | Invalid options |
| `6` | `tests` has no specs or no Jest config |
| `7` | Studio ran but reported no result, or timed out |
