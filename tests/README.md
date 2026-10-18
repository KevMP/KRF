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
| `npm run test:integration:networking-baseline` | Two-client delivery, privacy, and teardown under representative gameplay workloads |
| `npm run test:integration:n4-performance` | Native sustained publication load with two clients |
| `npm run test:integration:tags-load` | Native Tags delivery at multiple Actor populations |

The ActorView and TagsView commands build `n5-actor-view-test.project.json` and
`n6-tags-view-test.project.json`. Their PowerShell runners launch Studio's
Edit-DataModel `RunScript` task, whose Luau launcher calls
`StudioTestService:ExecuteMultiplayerTestAsync(2, ...)`. They retain places and logs
under `build/n5-native/<run-id>/` and `build/n6-native/<run-id>/`. Exit 0 requires a
verified success result; exit 1 reports a fixture failure; exit 2 means no result
was verified. To select Studio, invoke the corresponding
`scripts/test-n5-native.ps1` or `scripts/test-n6-native.ps1` with
`-StudioPath <absolute-path>`.

See [benchmark workflows](./benchmarks/README.md) for load projects, CPU
measurements, analyzers, and interpretation limits.

## Standalone Edit-mode fixtures

Keep these focused checks alongside the broader native suites:

| Project | Launcher | Distinct coverage |
| --- | --- | --- |
| `n4-association-test.project.json` | `scripts/run-n4-association-tests.luau` | Real Players and native Character changes between registered and unregistered Models; Owner reconciliation without rerunning canonical snapshots. Transport sends are captured by an injected sink. |
| `networking-test.project.json` | `scripts/run-networking-tests.luau` | Normal two-client initialization, native transport discovery, matching codebooks, acknowledgement-before-follow-up ordering, no handshake recompilation/domain callbacks, and readiness cleanup on departure |

Build the desired fixture:

```powershell
New-Item -ItemType Directory -Force build
rojo build n4-association-test.project.json -o build/KRF-N4-Association-Tests.rbxl
rojo build networking-test.project.json -o build/KRF-Networking-Tests.rbxl
```

Open the matching place in Studio **Edit mode**, then execute the matching Luau
launcher's contents from the command bar. `StudioTestService` requires that
security context; running these launchers inside a `run-in-roblox` simulation
does not provide it. Success prints `__KRF_NATIVE_N4_ASSOCIATION_PASS__` or
`__KRF_NATIVE_NETWORKING_PASS__` with structured results.

Optional local-plugin launchers remain in
`scripts/n4-association-test-plugin.server.luau` and
`scripts/networking-test-plugin.server.luau`. They run only in Edit mode after
detecting their fixture marker. The Networking plugin can be built with:

```powershell
rojo build networking-test-plugin.project.json -o build/KRF-Networking-Test-Plugin.rbxmx
```

Install that model in Studio's local Plugins directory only for the fixture run,
then remove it afterward. The command-bar path requires no plugin installation.
