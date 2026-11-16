# Releasing KRF

KRF's runtime ships as the Wally package `kevmp/krf`. The version in `main`'s `wally.toml` is the
release candidate: once CI passes on a `main` commit whose version has no tag,
[`release-wally.yml`](./.github/workflows/release-wally.yml) tags that commit, publishes it, reads
it back from the registry and starts it in a fresh consumer before finalizing the release.

## Version policy

| Item | Rule |
| --- | --- |
| Runtime version | `version` in the `[package]` table of `wally.toml`, using `MAJOR.MINOR.PATCH`. |
| Version changes | Only through a release PR. Any other change to `wally.toml`'s version releases it when merged. |
| Release tag | `vMAJOR.MINOR.PATCH`, created by the release workflow on the `main` commit that declares the version. |
| Prereleases | Not supported. Versions with `-` or `+` suffixes are rejected before publishing. |
| Immutability | A published version is never overwritten or republished. Fixes ship as a new version. |
| Release notes | The GitHub Release for the tag, created only after verification succeeds, listing the pull requests merged since the previous release. |
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

1. In GitHub Actions, run **Release PR** and choose `patch`, `minor` or `major`, or enter an exact
   version. It bumps `wally.toml`, `wally.lock` and the install snippets in `README.md` and
   [Initializing KRF](./docs-site/docs/documentation/initializing-krf.md), opens a
   `chore(release): vX.Y.Z` pull request and runs CI on it.
2. Review and merge the pull request.

Nothing else is manual. The bump refuses to start while `main`'s current version is still
unreleased, so versions are never skipped. If `main` moves before the merge, update the branch from
the pull request; that push runs CI again.

After CI passes on the merge commit, the release workflow runs these jobs:

| Job | Checks |
| --- | --- |
| `resolve` | Reads the commit's `wally.toml` version. Stops when that version is already tagged on another commit, which is the case for every `main` commit that is not a release. |
| `preflight` | Version syntax, tag/manifest equality, commit reachable from `main`, a successful CI run for the commit, release tooling tests, typecheck, lint, archive contents and size, and whether the registry already has the version. |
| `tag` | Creates the `vX.Y.Z` tag on the commit, unless it already exists there. |
| `publish` | Runs `wally publish` with the environment secret. Wally 0.3.2 exits `0` after an HTTP failure, so the job requires Wally's success message and fails on any `Error:` status. Skipped when the version already exists. |
| `verify` | Waits for the version in the registry index, downloads the archive and compares every file with the tagged source, installs it with `wally install` in a new consumer, builds that place with Rojo, and runs [`tests/consumer/Smoke.luau`](./tests/consumer/Smoke.luau) in Roblox. Then it creates the GitHub Release. |

CI runs the same smoke task against the packaged archive on every push, without publishing.

## Recovery

| Failure | Recovery |
| --- | --- |
| Release PR cannot open its pull request | Allow GitHub Actions to create pull requests in the repository's Actions settings, then run it again. |
| Preflight fails | Nothing was tagged or published. Fix the cause in a pull request; CI on its merge commit retries the release. |
| Tag creation refused | The `v*` tag ruleset must let GitHub Actions bypass it. Then re-run the failed jobs. |
| Publish rejected (`401`/`403`) | Fix `WALLY_PUBLISH_TOKEN` or scope ownership, then run the workflow manually with the tag. |
| Publish failed with a server error | Run the workflow manually with the tag. Preflight checks the registry first and verifies instead of publishing if the upload landed. |
| Verify failed after upload | Run the workflow manually with the tag. It skips publishing and repeats verification. |
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
