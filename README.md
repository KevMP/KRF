# Kevin's Roblox Framework (KRF)

KRF is a server-authoritative Luau gameplay framework for Roblox. It provides
Actor lifecycle, Tags and status effects, numeric Properties, Resources, Actions,
and schema-defined replication with immutable client ActorViews and typed TagsViews.
Games supply definitions, gameplay behavior, and presentation.

[Guides and API reference](https://kevmp.github.io/KRF/) describe the current
public contracts. The [charter](./CHARTER.md) records architectural direction and
planned systems; it is not a list of shipped features.

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
rojo serve default.project.json
```

The default project mounts KRF under `ReplicatedStorage.Packages.KRF`. Follow
[Initializing KRF](https://kevmp.github.io/KRF/initializing-krf) to integrate it
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
