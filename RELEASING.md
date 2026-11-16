# Releasing KRF

KRF's runtime ships as the Wally package `kevmp/krf`. A protected Git tag triggers
[`release-wally.yml`](./.github/workflows/release-wally.yml), which publishes the tagged source,
reads it back from the registry and starts it in a fresh consumer before finalizing the release.

## Version policy

| Item | Rule |
| --- | --- |
| Runtime version | `version` in the `[package]` table of `wally.toml`, using `MAJOR.MINOR.PATCH`. |
| Release tag | `vMAJOR.MINOR.PATCH` on a commit reachable from `main`, equal to that commit's `wally.toml` version. |
| Prereleases | Not supported. Tags with `-` or `+` suffixes are rejected before publishing. |
| Immutability | A published version is never overwritten or republished. Fixes ship as a new version. |
| Release notes | The GitHub Release for the tag, created only after verification succeeds. |
| Root `package.json` | Private repository tooling. Its `version` is not a KRF release version. |
| `create-krf` | Versioned independently on npm; it declares which KRF versions its templates support. |

While KRF is `0.x`, a minor version may change public contracts. Describe migrations in the
GitHub Release notes.

## Package contents

`wally.toml` publishes an explicit allowlist: `src/**`, `wally.toml`, `default.project.json`
(the package mapping `{ "$path": "src" }`) and `LICENSE`. Docs, tests, scripts, places and build
output are excluded. Wally 0.3.2 treats `include` as a force-include, so `exclude = ["*"]` drops
everything else. Check the file list with:

```bash
wally package --list
```

Consumers import KRF through the package root, `require(ReplicatedStorage.Packages.KRF)`, which
`src/init.luau` defines. `dev.project.json` mounts `src` into a development place.

## Publish a release

1. Change `version` in `wally.toml` on a branch and merge it into `main`.
2. Wait for CI to pass on the merge commit.
3. Tag that commit and push the tag:

   ```bash
   git tag v0.1.0 <commit>
   ```

   ```bash
   git push origin v0.1.0
   ```

4. Approve the `wally-release` deployment when GitHub asks.

The workflow then runs three jobs:

| Job | Checks |
| --- | --- |
| `preflight` | Tag syntax, tag/manifest equality, commit reachable from `main`, a successful CI run for the commit, release tooling tests, typecheck, lint, archive contents and size, and whether the registry already has the version. |
| `publish` | Runs `wally publish` with the environment secret. Wally 0.3.2 exits `0` after an HTTP failure, so the job requires Wally's success message and fails on any `Error:` status. Skipped when the version already exists. |
| `verify` | Waits for the version in the registry index, downloads the archive and compares every file with the tagged source, installs it with `wally install` in a new consumer, builds that place with Rojo, and runs [`tests/consumer/Smoke.luau`](./tests/consumer/Smoke.luau) in Roblox. Then it creates the GitHub Release. |

CI runs the same smoke task against the packaged archive on every push, without publishing.

## Recovery

| Failure | Recovery |
| --- | --- |
| Preflight rejects the tag | Nothing was published. Fix the cause on `main`; if the tag points at the wrong commit, a maintainer may delete and recreate the unpublished tag. |
| CI has not passed for the commit | Wait for CI, then run the workflow manually with the tag. |
| Publish rejected (`401`/`403`) | Fix `WALLY_PUBLISH_TOKEN` or scope ownership, then run the workflow manually. |
| Publish failed with a server error | Run the workflow manually. Preflight checks the registry first and verifies instead of publishing if the upload landed. |
| Verify failed after upload | Run the workflow manually. It skips publishing and repeats verification. |
| Registry contents differ from the tag | Do not republish. Investigate, then release a new patch version. |
| Registry unavailable | The state is unknown, not absent. Retry later. |

Wally cannot remove a published version. To withdraw a broken release, publish a fixed patch
version and note the problem in the earlier GitHub Release.

## npm packages

[`create-krf`](./packages/create-krf) and [`krf-tools`](./packages/krf-tools) version
independently of the runtime and of each other. Generated projects pin an exact `krf-tools`
version, so publish order matters:

1. Publish `krf-tools`, then confirm it installs from the public registry in a clean directory.
2. Publish `create-krf`, whose `dependencies` and generated projects pin that exact version.

`create-krf` records the KRF runtime version its templates target in
[`src/compatibility.js`](./packages/create-krf/src/compatibility.js); it must name a verified
Wally release. Public npm publication is gated on the full generated-project test matrix and is not
automated yet. Before publication, `npm run test:packages:integration` proves the packed tarballs
create a working project without workspace links.

## Release status

[`release-status.yml`](./.github/workflows/release-status.yml) runs weekly, after release runs,
when `wally.toml` changes on `main`, and on demand. It reports the latest release tag, the
tagged and `main` manifest versions, the latest verified registry version and one state per tag:

| State | Meaning |
| --- | --- |
| Released and verified | Tagged, in the registry, and its GitHub Release exists. |
| Candidate on main (not yet tagged) | `main` declares a version with no tag. |
| Tagged but not published | The registry index does not list the tagged version. |
| Present in registry, consumer verification incomplete/failed | Published, but verification has not finished. |
| Tag/manifest mismatch | The tagged `wally.toml` declares another version. |
| Registry unavailable / status unknown | The registry could not be read; no tag is reported as absent. |
| In registry without a release tag | The registry lists a version with no matching tag. |

Run it locally with `node scripts/release-wally.cjs status`; it needs `git` and an authenticated
`gh`.
