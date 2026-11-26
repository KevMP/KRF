# Kevin's Roblox Framework (KRF)

KRF is a server-authoritative Luau gameplay framework for Roblox. It provides
Actor lifecycle, Tags and status effects, numeric Properties, Resources, Actions,
and schema-defined replication with immutable client ActorViews, TagsViews, and ResourcesViews.
Games supply definitions, gameplay behavior, and presentation.

[Reference](https://kevmp.github.io/KRF/reference/) describes the shipped systems
and their APIs. [Build a cultivation game](https://kevmp.github.io/KRF/tutorial/)
walks through a complete small project. The [charter](./CHARTER.md) records architectural direction and
planned systems; it is not a list of shipped features.

## Install

Add KRF to a game's `wally.toml` and run `wally install`:

```toml
[dependencies]
KRF = "kevmp/krf@0.2.1"
```

Mount Wally's `Packages` folder at `ReplicatedStorage.Packages`, then import KRF through its
package module: `require(ReplicatedStorage.Packages.KRF)`. See
[Initializing KRF](https://kevmp.github.io/KRF/reference/getting-started/initialization). Maintainers publish releases
as described in [RELEASING.md](./RELEASING.md).

## Setup

Local framework tests require Windows, Roblox Studio, Node.js with npm, and
[Rokit](https://github.com/rojo-rbx/rokit). Use Node.js 20 or newer for the docs site.
From the repository root:

```powershell
rokit install
wally install
npm ci
```

Rokit installs the pinned Roblox tools in `rokit.toml`; Wally installs the test
dependencies. To sync the framework into a Studio place with the Rojo plugin:

```powershell
rojo serve dev.project.json
```

The dev project mounts KRF under `ReplicatedStorage.Packages.KRF`.
`default.project.json` is the Wally package project and maps only `src`. Follow
[Initializing KRF](https://kevmp.github.io/KRF/reference/getting-started/initialization) to integrate it
with game startup.

## Development

Run these commands from the repository root:

| Command | Purpose |
| --- | --- |
| `npm test` | Formatting, lint, strict Luau analysis, unit tests, and coverage gates |
| `npm run test:lint` | StyLua, breathers, and Selene checks |
| `npm run typecheck` | Generate the test sourcemap and run Luau analysis; downloads Roblox definitions |
| `npm run test:unit` | Run Jest-Lua in Studio and check per-file coverage |
| `npm run test:integration:n5` | Native two-client ActorView lifecycle and recovery coverage |
| `npm run test:integration:n6` | Native two-client Tags replication and TagsView coverage |
| `npm run test:integration:n7` | Native two-client Resources replication, interpolation, recovery, and teardown coverage |
| `npm run test:packages` | Unit tests for the `create-krf` and `krf-tools` npm packages in `packages/` |
| `npm run test:packages:integration` | Create both project modes from packed `create-krf` and `krf-tools` tarballs, run every definition generator through npm scripts, then check and build |
| `npm run test:packages:configurations` | Create, install, build and check every supported creator configuration from packed tarballs |
| `npm run test:integration:starter` | Play generated starter projects in Studio with one server and two clients |

Run Studio jobs serially. See [test workflows](./tests/README.md) for standalone
integration fixtures, [benchmarks](./tests/benchmarks/README.md) for load and
measurement commands, and [AGENTS.md](./AGENTS.md) for repository conventions.

## Documentation development

```powershell
npm --prefix docs-site ci
npm --prefix docs-site start
npm --prefix docs-site run build
```

See the [docs-site README](./docs-site/README.md) for preview and deployment details.
