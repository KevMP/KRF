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
   [Initializing KRF](./docs-site/docs/reference/getting-started/initialization.md), opens a
   `chore(release): vX.Y.Z` pull request and runs CI on it.
2. Review and merge the pull request.

Nothing else is manual. The bump refuses to start until `main`'s current version has a verified
GitHub Release, so versions are never skipped. If `main` moves before the merge, update the branch from
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
| Tag creation refused | The `v*` tag ruleset must not restrict creations. Then re-run the failed jobs. |
| Publish rejected (`401`/`403`/`422`) | `WALLY_PUBLISH_TOKEN` must be the token `wally login` stores in `~/.wally/auth.toml`; the registry rejects other GitHub tokens. Fix it or the scope ownership, then re-run the failed jobs. |
| Publish failed with a server error | Run the workflow manually with the tag. Preflight checks the registry first and verifies instead of publishing if the upload landed. |
| Verify failed after upload | Run the workflow manually with the tag. It skips publishing and repeats verification. |
| Registry contents differ from the tag | Do not republish. Investigate, then release a new patch version. |
| Registry unavailable | The state is unknown, not absent. Retry later. |

Wally cannot remove a published version. To withdraw a broken release, publish a fixed patch
version and note the problem in the earlier GitHub Release.

## npm packages

[`create-krf`](./packages/create-krf) and [`@kevmp/krf-tools`](./packages/krf-tools) are published to npm
by [`release-npm.yml`](./.github/workflows/release-npm.yml), which a maintainer starts by hand. They
version independently of the runtime, and every generated project depends on the exact `@kevmp/krf-tools`
release its creator pinned, so `@kevmp/krf-tools` is always published first. Its executable is
still called `krf-tools`, which is what generated projects' npm scripts run.

`create-krf` records the KRF runtime version its templates target in
[`krf-tools/src/compatibility.js`](./packages/krf-tools/src/compatibility.js) as `KRF_RUNTIME`.
It must name a verified Wally release, and `SUPPORTED_KRF_VERSIONS` lists every runtime the tools accept.

### Bump the versions

In a pull request, set `version` in both packages' `package.json`, and set `create-krf`'s
`@kevmp/krf-tools` dependency to the new `@kevmp/krf-tools` version exactly. Then run `npm install` so
`package-lock.json` follows. Both versions must be new on npm, even when only one package changed,
because the creator pins the tools it was tested with. Prereleases aren't supported.

CI on that pull request creates a project from the packed tarballs for every configuration the
creator accepts: each mode and place layout, with and without CI, agent files and Git. Each project
is installed, built and checked. The list comes from the creator's option schema, so a new creator
option fails the `configurations` job until
[`tests/configurations/configurations.test.js`](./packages/create-krf/tests/configurations/configurations.test.js)
has a flag for it. Run it locally with `npm run test:packages:configurations`.

### Publish

After the pull request is merged and CI has passed on `main`, run **Release (npm)** from `main` in
GitHub Actions. It has three jobs:

| Job | What it does |
| --- | --- |
| `preflight` | Refuses to continue unless the commit is on `main`, CI passed on it, both versions are release versions that npm doesn't have, `create-krf` pins the `@kevmp/krf-tools` version being published, and `KRF_RUNTIME` has a GitHub Release. Then it packs both tarballs, creates every configuration from those exact files, and uploads them. |
| `publish` | Runs in the `npm-release` environment and publishes the uploaded tarballs with npm trusted publishing: `@kevmp/krf-tools`, then `create-krf`. Provenance is attached automatically. A version npm already has with the same integrity is skipped, so re-running the job after a partial publish finishes it. |
| `verify` | Waits until npm serves both versions with the tested integrity, runs `npx create-krf@<version> smoke --yes` in a clean directory with an empty npm cache, then installs and builds that project. |

### Recovery

| Failure | Recovery |
| --- | --- |
| `preflight` fails | Nothing was published. Fix the cause in a pull request and run the workflow again on the new `main` commit. |
| `publish` fails before npm accepts `@kevmp/krf-tools` | Nothing was published. Fix the cause, for example the trusted publisher settings, then choose **Re-run failed jobs**. |
| `publish` fails after `@kevmp/krf-tools` is published | Choose **Re-run failed jobs**. The job skips `@kevmp/krf-tools` because npm has the same tarball, then publishes `create-krf`. Don't start a new run: its preflight stops because `@kevmp/krf-tools` already exists. |
| npm has a version with other contents | Someone published that version outside the workflow. Don't overwrite it: bump both versions and release again. |
| `verify` fails | npm has already accepted both versions, and the workflow never republishes. Re-run `verify` if the failure was a registry delay or network error. Otherwise fix the problem, bump both versions, and release again; deprecate the broken versions with `npm deprecate <package>@<version> "<reason>"`. |

### First-time setup

npm sets up trusted publishing only for a package that already exists. So before the first
release, a maintainer publishes a placeholder of each package from their own machine and then links
it to the workflow. These steps need npm 11.15 or later and an npm account with two-factor
authentication.

1. In the repository settings, create an environment named `npm-release`, and limit its deployment
   branches to `main`.
2. Publish a placeholder for each package. In an empty directory, create a `package.json` like this
   one, then run `npm publish --access public`. Repeat with the name `@kevmp/krf-tools`.

   ```json
   {
     "name": "create-krf",
     "version": "0.0.0",
     "description": "Placeholder. Install a later version.",
     "repository": { "type": "git", "url": "git+https://github.com/KevMP/KRF.git" }
   }
   ```

3. Link each package to the workflow, then deprecate its placeholder:

   ```bash
   npm trust github @kevmp/krf-tools --file release-npm.yml --repo KevMP/KRF --env npm-release --allow-publish
   npm trust github create-krf --file release-npm.yml --repo KevMP/KRF --env npm-release --allow-publish
   npm deprecate @kevmp/krf-tools@0.0.0 "Placeholder. Install a later version."
   npm deprecate create-krf@0.0.0 "Placeholder. Install a later version."
   ```

4. Run **Release (npm)** within two days. npm discards a trusted publisher whose first publish
   doesn't happen within that time, and you'd have to run `npm trust` again.

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
