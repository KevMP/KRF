---
title: Project tools
---

# Project tools

Projects created with `create-krf` include npm scripts for local development and definition generation. Run them from the generated game's root. They use the pinned `@kevmp/krf-tools` package and Roblox tools in that project, so a global generator install is unnecessary.

To create the project itself, run `npm create krf@latest`, or follow [Create a KRF project](/tutorial/create-the-project) for a walkthrough. The commands here describe a generated game; the framework repository has its own contributor commands in its README.

## Work on the game

| Command | Purpose |
| --- | --- |
| `npm run dev` | Opens the place in Studio, serves source through Rojo, and captures each Studio save into source; see [World](./world) |
| `npm run build` | Builds a place file with Rojo |
| `npm run check` | Checks formatting, lint and Luau types without formatting source; refreshes type-analysis artifacts |
| `npm run format` | Formats source and tests |
| `npm test` | Runs the game's Jest Lua specs in Studio |
| `npm run test:studio` | Starts a server and clients to check KRF startup and character views |
| `npm run world:syncback` | Syncs a place saved from Studio back into source files; see [World](./world) |

`dev` stays attached while Rojo serves changes. Connect the Rojo plugin in Studio, then press Play. Ctrl+C stops the server started by the command; it leaves Studio open. If the place is already open, `dev` serves without rebuilding or reopening it.

Full projects build their place from `default.project.json`, including the world captured in `world/`. Hybrid projects keep the Studio-authored world in their place file and sync source and Packages; `build` writes a separate place under `build/`. The first Hybrid development run creates the initial world place, and later runs preserve it.

Pass workflow options after `--`:

| Option | Applies to |
| --- | --- |
| `--no-open` | `dev`: serve without opening Studio |
| `--no-syncback` | `dev`: don't sync Studio saves back into source |
| `--port <port>` | `dev`: integer from 1 to 65535; default 34872; a busy port fails rather than replacing another server |
| `--place <file>` | Hybrid `dev`: select the world place |
| `--studio-path <path>` | Studio workflows: explicit executable path |
| `--timeout <seconds>` | Test workflows: integer from 1 to 3600; default 300 |
| `--clients <count>` | `test:studio`: 1 to 8 clients; default 2 |

Opening Studio and running the Studio test workflows need Windows or macOS with Roblox Studio installed. Checks and builds can run wherever the pinned Rokit tools run. Test artifacts stay under ignored `build/krf/<run>/`; only one Studio test runs per project at a time.

The [testing chapter](/tutorial/test-the-game) shows a useful KRF spec and links to Jest Lua's assertion and hook documentation.

## Generate a definition

```bash
npm run createAction -- --name Meditate --recipe held --requestable --auto-grant --yes
```

The generator writes a typed `--!strict` module. Catalog loaders discover generated modules on the next build. For a catalog not present in the starter, it can create the loader and wire it into startup while that script retains the structure the generator recognizes.

| Script | Catalog folder under `src/server` | Startup field |
| --- | --- | --- |
| `createAction` | `Actions` | `actions` |
| `createTag` | `Tags` | `tags` |
| `createResource` | `Resources` | `resources` |
| `createProperty` | `Properties` | `properties` |
| `createController` | `Controllers` | `controllers` |
| `createDomain` | `ReplicationDomains` | `replicationDomains` |
| `createCommand` | `Commands` | `commands` |
| `createHint` | `Hints` | `hints` |

If startup already supplies a catalog from a different folder, generation follows that folder where it can recognize the wiring. A generated definition still needs authored behavior and valid references. Resolve warnings about unknown Tags, Resources, Properties or Actions before starting the game.

Generator defaults are template choices. `createResource` enables automatic assignment unless you pass `--no-auto-assign`; the [hand-authored Resource default](../resources/api#resource-definition) is false. `createDomain` defaults to Owner, while a [domain definition](../replication/api#replicationdomaindefinition) with no audience uses All.

### Common flags

| Flag | Meaning |
| --- | --- |
| `--name <Name>` | PascalCase module name; default definition ID |
| `--id <id>` | Explicit ID or Controller key; a namespaced ID nests the default path |
| `--output <path>` | Explicit module path relative to the project |
| `--dry-run` | Report the plan without writing |
| `--json` | One structured result object on stdout |
| `--yes`, `-y` | Use defaults for missing options without prompting |
| `--help` | The selected generator's complete option list |

Without `--yes`, a terminal wizard asks for missing choices. Noninteractive and JSON calls use defaults. For machine-readable output, suppress npm's own banner with `npm run --silent createTag -- --name Winded --yes --json`.

### Action recipes and client requests

| Recipe | Generated lifetime |
| --- | --- |
| `instant` | Ends in `onStart` |
| `channel` | Accumulates `onUpdate` time and ends after `--duration` |
| `held` | Ends when `onStopRequested` runs; requestable form uses WhileDown |
| `toggle` | Ends when `onStopRequested` runs; requestable form uses Toggle |

Recipes generate callbacks, not runtime Action kinds. `--requestable` also creates a shared request entry and, where needed, a client input policy. `--start-field` and `--stop-field` declare payload fields with syntax such as `--start-field "Strength:F32"` or `--stop-field "Direction:Array(F32,3)"`. Generated parameter producers initially return schema-valid placeholder values; replace them with the player's intended data.

`--client-stop`, `--allow-input-interrupt` and `--on-disconnect` customize the wire contract where the recipe allows it. Held requests require release and disconnect interruption. Requestable Actions default to ClientVisible, but visibility is independent of request permission and can remain ServerOnly.

The generator leaves input bindings alone. In the starter, `Controls/Keybinds.luau` declares slots and `Controls/Loadout.luau` chooses their Actions. See [Action routes](../actions/routes) before adapting that wiring.

Other flags map to the system's ordinary definition fields: Tag modifiers and durations, Resource bounds and regeneration, Controller dependencies, domain state/events, and Command/Hint schemas. Use the relevant system's API for semantics and `--help` for CLI spellings. Generated Command handlers and client-originated Hint receivers are stubs; the default authorization stub denies with `NotImplemented`.

## Read the result before rerunning

| Status | Exit code | Next step |
| --- | --- | --- |
| `created` | 0 | Edit behavior; the module is wired |
| `dry-run` | 0 | Inspect `outcome`; nothing was written |
| `already-exists` | 3 | Edit the existing module; nothing was overwritten |
| `created-not-loaded` | 4 | Move the module into the loaded catalog or wire it yourself |
| `manual-wiring-required` | 5 | Add the reported startup/loader lines |
| Invalid arguments | 2 | Correct options; nothing was written |
| Other errors / cancellation | 1 / 130 | Read the error; no completed generation |

The tool does not overwrite existing definitions or guess how to rewrite arbitrary startup code. It validates and plans writes first; a failed write removes its created files and restores edited files. A partial wiring result can leave the new module present, so repeating the command produces `already-exists`, not a wiring repair.

With `--json`, a result includes `status`, `kind`, `name`, `id`, `file`, planned `changes`, manual wiring instructions, suggested next steps and warnings. An error instead returns `status = "error"` with its code, message and optional hint. Diagnostics go to stderr.

The generator checks the installed KRF version in `wally.lock`, or the exact `wally.toml` pin before installation. An unsupported version writes nothing and identifies the needed tooling update. Keep the project's pinned tool/runtime versions compatible when upgrading.
