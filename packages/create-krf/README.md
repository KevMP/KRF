# create-krf

Creates a Roblox game project that uses [KRF](https://kevmp.github.io/KRF/) `kevmp/krf@0.2.0`.

```bash
npm create krf@latest
```

```bash
npx create-krf@latest my-game --yes
```

For a Full game with a lobby and a dungeon, scaffold both places together:

```bash
npm create krf@latest my-game -- --yes --places lobby,dungeon
```

The first name sets `krf.startPlace` in `package.json`. The scaffold creates
`places/lobby.project.json` and `places/dungeon.project.json`, with starter world files under
`world/lobby/` and `world/dungeon/` and shared code in `src/`. Run `npm run dev` to open the lobby in
Studio, `npm run dev -- --place dungeon` to work on the dungeon instead, or `npm run build` to build both.

Requires Node.js 22.12 or newer. The project's npm scripts call the Roblox tools pinned in its
`rokit.toml`: Rojo, Wally, StyLua, Selene and luau-lsp. Its `npm install` installs Rokit when it
is missing, then those tools and the Wally packages. Its only npm dependency is `krf-tools`, which runs
[`npm run dev`, `npm test` and `npm run test:studio`](https://kevmp.github.io/KRF/reference/getting-started/project-tools#work-on-the-game), `npm run world:syncback` (see [World](https://kevmp.github.io/KRF/reference/getting-started/world)), and the
[definition generators](https://kevmp.github.io/KRF/reference/getting-started/project-tools#generate-a-definition) such as `npm run createAction`. It is pinned to the exact release this creator ships with; when the
creator itself was installed from a local `krf-tools` tarball, the project depends on that same
tarball instead, so `npm install` works before the packages are published.

## Options

Without `--yes`, an interactive terminal asks for the name, mode, optional Full place names, CI workflow and agent files when they are not
given as flags. With `--yes`, or without a terminal, missing values use the defaults.

| Flag | Values | Default |
| --- | --- | --- |
| `[project-name]` | Lowercase letters, digits, `-`, `_`, `.` | Asked; required without a terminal |
| `--mode` | `full`: code and world live in the repository, and `npm run dev` builds the whole place. `hybrid`: only code and packages live in the repository; you build the world in Studio and keep the place file | `full` |
| `--places` | Full mode only. Comma-separated names such as `lobby,dungeon`, with the start place first | One unnamed starter place |
| `--ci` / `--no-ci` | A GitHub Actions workflow that checks and builds on every push and pull request | `--ci` |
| `--agents` / `--no-agents` | `AGENTS.md`, a `CLAUDE.md` that imports it, and the KRF skill in both `.agents/skills/krf/` (Codex) and `.claude/skills/krf/` (Claude Code), so coding agents can build the game with KRF | `--agents` |
| `--no-git` | Skip `git init`, which otherwise runs unless the target is already inside a repository | |
| `-y`, `--yes` | Use defaults for every missing value; never prompt | |

Every value is validated before anything is written. The target must not exist or must be empty,
and files are written through a staging directory, so a failure leaves no partial project.

| Exit code | Meaning |
| --- | --- |
| `0` | Created |
| `1` | Creation failed, or `git init` failed after the files were written |
| `2` | Invalid arguments; nothing was written |
| `130` | Cancelled; nothing was written |

## Contributing

From the repository root, with the Rokit tools in the repository's `rokit.toml` installed:

```bash
npm run test:packages
```

```bash
npm run test:packages:integration
```

```bash
npm run test:integration:starter
```

To try an unpublished build by hand, pack both packages and run the creator from the tarballs in
any folder:

```bash
npm pack --pack-destination build/tarballs --workspace krf-tools --workspace create-krf
```

```bash
npx --yes --package <repo>/build/tarballs/krf-tools-0.1.0.tgz --package <repo>/build/tarballs/create-krf-0.1.0.tgz create-krf
```

The integration test creates both modes from packed tarballs, installs the packed `krf-tools` and
the published KRF, runs every definition generator through the project's npm scripts, checks,
builds and inspects each place, and reads Hybrid's live-sync ownership from `rojo serve`. The world test
saves the scene in `tests/integration/fixtures/Arena.rbxmx` into a place, captures it with `npm run world:syncback`
in both modes, rebuilds it, and checks hierarchy, properties, attributes and references. The starter test plays generated projects in Studio with one server and two clients;
see [test workflows](../../tests/README.md#starter-project).

Templates live in `templates/`: `base`, plus `full` for the Full starter world, and `ci` and `agents` when selected. The skill template is in `_agents/skills/krf/`, and the creator writes a copy of it to `.claude/skills/krf/` as well, since Claude Code doesn't read `.agents/skills`. Packing copies
the reference docs from `docs-site/docs/reference` into the skill's `references/docs/`, rewriting their links so they resolve
inside the skill; the copy is removed after packing. `npm run typecheck` checks every Luau example in the skill references
against `src`: each reference has a small game tree under `tests/fixtures/skill-examples/<reference>/`, and a
`--@example N` line in it marks where the reference's Nth `lua` block goes. Every block must be placed exactly once. Rojo
projects, `package.json`, `rokit.toml` and `wally.toml` are generated by
`src/manifests.js`. `.ejs` files render with the project data; a leading `_` in a name becomes `.`.
