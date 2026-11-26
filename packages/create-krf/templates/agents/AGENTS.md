# Agent instructions

This is a Roblox game built with KRF. Before writing gameplay, read the KRF skill in `.agents/skills/krf/SKILL.md`.

## Layout

- `src/server` is `ServerScriptService.Game`, `src/shared` is `ReplicatedStorage.Shared`, and `src/client` is `StarterPlayerScripts.Game`. `default.project.json` holds the mapping.
- Require KRF from `ReplicatedStorage.Packages.KRF`. On the client, reach `ReplicatedStorage` children with `WaitForChild`.
- Never edit `Packages` or `DevPackages`. Wally rewrites them on every `npm install`.

## Catalog folders

- Every ModuleScript in a catalog folder, such as `src/server/Tags` or `src/server/Actions`, is loaded as a definition, subfolders included. Put shared helpers outside catalog folders.
- `src/shared/ActionRequests` and `src/client/ActionInputPolicies` merge maps keyed by Action ID. Startup fails if two modules declare the same ID.
- Create definitions with the generators (`npm run createAction` and the others), never by hand.

## Startup

- `src/server/Startup.server.luau` and `src/client/Startup.client.luau` call `KRF.Server.Init` and `KRF.Client.Init` once each. Never call `Init` anywhere else.
- Start the game's own systems from those scripts after `Init` succeeds, with a module that has a `Start` function, as `PlayerActors` and `Controls` do.
- Never register an Actor before the server's `Init` has returned.

## Commands

- `npm run check` checks formatting, lint and types. Run it after every change. When it fails on formatting, run `npm run format`.
- `npm run build` builds the place.
- `npm test`, `npm run test:studio` and `npm run dev` need Roblox Studio on Windows or macOS. When Studio isn't installed, run `check` and `build`, and say the Studio scripts were not run.
- `npm run dev` runs until it's stopped. Never run it as a command you wait for.

## Tests

- Specs are `tests/**/*.spec.luau`. Keep `tests/jest.config.luau` and `tests/Definitions.spec.luau`.
- `npm test` runs Jest in Studio without pressing Play. The startup scripts don't run and there are no players.
- Each spec calls `KRF.Server._ResetForTests()` and `KRF.Server.Init` with the catalogs it needs in `beforeEach`, registers its own Models, and unregisters them, destroys them and resets KRF again in `afterEach`. Never call `_ResetForTests` from game code.
- Pass the game's real catalogs, such as `require(ServerScriptService.Game.Resources)`, so specs check the definitions the game ships.
- Exit code 1 means a spec failed, 6 means no specs or no Jest config, and 7 means Studio couldn't run the tests, which isn't a test failure.
- Specs cover server rules. For client code, input and UI, tell the user what to try in a Studio play session.

## Code

- Keep `--!strict` in every module. Fix type errors instead of silencing them with `:: any`.
- Don't change the KRF version in `wally.toml` or the `krf-tools` version in `package.json` as part of a feature. Commit `wally.lock`.
