# Test workflows

Install the [repository prerequisites and dependencies](../README.md#setup).
Run commands from the repository root. Run all Studio jobs serially, including
unit tests: `run-in-roblox` temporarily installs a shared local Studio plugin.
Keep generated places, logs and observations under ignored `build/` directories;
unit coverage is written to ignored `coverage/` and `.nyc_output/`.

## Unit tests and static checks

`npm test` runs formatting/lint, strict Luau analysis, Jest-Lua, and the unchanged
per-file coverage gates. Use `npm run test:unit` for focused test work. Specs live
under `tests/server`, `tests/client`, and `tests/shared`; injected integration
specs exercise cross-system contracts without replacing native fixtures.

`npm run typecheck` also compiles the Presentation `On` and `Watch` fixtures under
`tests/typecheck`. Positive fixtures exercise the supported call forms; negative
fixtures must produce errors at each `-- expect-error` marker and nowhere else.
They use the same pinned LuauSolverV2 checker and Roblox definitions as source
analysis. Generated fixture modules stay under ignored `.typecheck/`.

`test.project.json` mounts source, tests, and Wally dependencies for
`tests/run-tests.luau`. CI builds that same project and uses
`scripts/upload_and_run_task.py` and `scripts/luau_execution_task.py` to run it
through Roblox Open Cloud. Its Python tooling checks run with:

```powershell
python -m unittest discover -s scripts -p 'test_*.py'
```

## Native integration tests

These fixtures run real server/client sessions separately from `npm test`:

| Command | Coverage |
| --- | --- |
| `npm run test:integration:n5` | Normal startup and consumer installation, ActorViews, live commits, rate-limited recovery, Owner privacy, terminal halt, removal, respawn, and reset |
| `npm run test:integration:n6` | Normal startup, visible/private Tags, typed views and events, replacement, expiry, removal, respawn, and reset |
| `npm run test:integration:n7` | Normal two-client startup, visible/private Resources, local regeneration without recurring packets, assignment and rate changes, replacement, removal, respawn, and reset |
| `npm run test:integration:presentation` | Native catalog startup and rollback, late Actions domain membership, Highlight instances, activation-scoped end/interruption, Tag/Resource/Hint follow-ups, privacy, yielding callbacks, and teardown |
| `npm run test:integration:networking-baseline` | Two-client delivery, privacy, and teardown under representative gameplay workloads |
| `npm run test:integration:n4-performance` | Native sustained publication load with two clients |
| `npm run test:integration:tags-load` | Native Tags delivery at multiple Actor populations |

The Rojo projects for these suites and the manual Studio fixtures live in
[tests/integration/projects](./integration/projects/). The shared PowerShell
runner launches Studio in Edit mode and starts two clients through
`StudioTestService`. The n5 and n6 suites write places, launchers, and logs to
`build/n5-native/<run-id>/` and `build/n6-native/<run-id>/`. A verified success
returns exit code 0. A fixture failure returns 1. A missing result returns 2.

Pass a Studio executable explicitly with:

```powershell
npm run test:integration:n5 -- -StudioPath "C:\Path\To\RobloxStudioBeta.exe"
```

See [benchmark workflows](./benchmarks/README.md) for load projects, CPU
measurements, analyzers, and interpretation limits.

## Starter project

`npm run test:integration:starter` packs `create-krf` and `@kevmp/krf-tools`, generates
projects through the packed creator, installs the packed `@kevmp/krf-tools` and the
published KRF release with `npm install`, creates one definition of every kind
through the project's `npm run create*` scripts, builds with `npm run build`, and
plays each project in Studio with one server and two clients. The `starter`
scenario also runs the project's own `npm test` and `npm run test:studio`. The generated
project is not changed beyond the generated definitions and each scenario's edit;
the runner only adds its fixtures from `packages/create-krf/tests/native/` and a
control RemoteEvent.

| Scenario | Coverage |
| --- | --- |
| `starter` | Player character Actors, built-in controllers, one `Server.Init` and `Client.Init`, Focus held through its real ability-slot binding, an emptied slot starting nothing, `Focused` regenerating Energy while held and release ending it, the Energy display, ActorViews on both clients, a test-only ServerOnly Tag never reaching clients, respawn, destroyed characters and player departure |
| `late-model` | Controls starts after the local character's ActorView is published but before its Model replicates, then takes control when the Model arrives |
| `example-removed` | Startup and player Actors with the example definitions, Controls and Energy display deleted |
| `invalid-definitions` | A rejected startup reports its failure and registers no Actors |
| `generated` | `Server.Init` accepts the generated Action, Tag, Resource, Controller, Command, Hint and replication domain; the Controller attaches and the Resource is assigned; the channel Action ends after its duration; a client requests the generated requestable Action, which pays its cost; the generated Command and client-to-server Hint reject client calls |

Pass scenario names to run a subset, for example
`npm run test:integration:starter -- starter`. Places and logs stay under
`build/starter-native/<run-id>/`. Set `KRF_STUDIO_PATH` to choose Studio.

## Package consumer smoke

[`consumer/Smoke.luau`](./consumer/Smoke.luau) starts KRF from an installed
package through `require(ReplicatedStorage.Packages.KRF)` only: `Server.Init`,
Actor registration, an Action request, its Resource cost, and owned and applied
Tags. Build a consumer place from the packaged archive, mounted exactly as
`wally install` mounts it, and run the task in Studio:

```powershell
node scripts/release-wally.cjs consumer --source archive --out build/consumer/archive
```

```powershell
run-in-roblox --place build/consumer/archive/consumer.rbxl --script build/consumer/archive/Smoke.luau
```

CI runs the same task against the archive through Open Cloud. The release
workflow runs it against the published version installed from the registry
(`--source registry --version X.Y.Z`). `npm run test:release-tools` covers the
release helpers in `scripts/release/`; see [RELEASING.md](../RELEASING.md).

## Association and Networking startup

| Command | Coverage |
| --- | --- |
| `npm run test:integration:n4-association` | Real Players and Character changes between registered and unregistered Models, and Owner reconciliation without rerunning canonical snapshots. An injected sink captures transport sends. |
| `npm run test:integration:networking` | Two-client initialization, native transport discovery, matching codebooks, acknowledgement ordering, no handshake recompilation or domain callbacks, and readiness cleanup on departure. |

Optional local-plugin launchers remain in
`tests/integration/studio/n4-association-test-plugin.server.luau` and
`tests/integration/studio/networking-test-plugin.server.luau`. They run only in Edit mode after
detecting their fixture marker. The Networking plugin can be built with:

```powershell
rojo build tests/integration/projects/networking-test-plugin.project.json -o build/KRF-Networking-Test-Plugin.rbxmx
```

Install that model in Studio's local Plugins directory only for the fixture run,
then remove it afterward. The npm commands run without a local plugin.
