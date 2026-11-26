# Environments and deployment

A KRF game runs in four environments: Local, Dev, QA and Production. Local is Studio on the developer's machine. Dev, QA and Production are Roblox universes, and publishing to one replaces its live places, so publish only when the user asks you to.

## Environments

| Environment | What it's for | How the game gets there | Key |
| --- | --- | --- | --- |
| Local | Building and playtesting in Studio | `npm run dev`, or `npm run build` for a place file. Nothing is published | None |
| Dev | Each developer's own universe, for trying a change on Roblox's servers | `npm run deploy:dev -- --developer <name>` on that developer's machine | `KRF_ROBLOX_DEV_KEY`, in the Git-ignored `.env` or the shell |
| QA | The team's universe for playing a build before it's released | The **Deploy** workflow with `qa`, or **Release** after a version bump is merged | The `KRF_ROBLOX_QA_KEY` repository secret |
| Production | The universe players join | The **Deploy** workflow with `prod`, on a release tag that passed QA | The `KRF_ROBLOX_PROD_KEY` repository secret |

Local needs no setup. The other three are in `package.json` under `krf.deployment`: the group that owns the universes, each developer's Dev universe and its places, and the QA and Production universes. [cloud-deployment.md](docs/getting-started/cloud-deployment.md#set-up-the-dev-targets) shows the shape. Don't invent IDs. If a universe is missing, ask the user for its universe and place IDs.

Only Full projects publish from the command line. A Hybrid project's world lives in its Studio place, so the user publishes it from Studio, and the deploy commands fail with `unsupported-project-mode`.

## Check a universe

These two commands change nothing, so you can run them whenever deployment comes up:

```bash
npm run env:list -- --json
npm run deploy:dev -- --developer alex --verify-target --json
```

`env:list` lists the configured universes and whether each one's key is set, without contacting Roblox. `--verify-target` asks Roblox whether the key can publish to that developer's Dev universe, without building or publishing.

## Publish to Dev

`npm run deploy:dev -- --developer <name>` builds the game and publishes it to that developer's Dev universe. `KRF_DEVELOPER` can stand in for `--developer`.

- Uncommitted changes stop it with `dirty-worktree`. Commit first. Pass `--allow-dirty` only when the user wants to try uncommitted work.
- `npm run open:dev -- --developer <name>` prints the URL of the universe's start place. In a game with several places, add `--place <name>` for another one.

## Release to QA and Production

QA and Production publish from GitHub Actions, in a Full project created with `--ci`. The `deploy:qa`, `deploy:prod`, `release:pr` and `release:tag` scripts are what those workflows run; don't run them locally.

1. The user runs **Release PR**, which bumps `version` in `package.json` and opens a pull request. GitHub holds CI on a pull request that Actions opens, so someone with write access chooses **Approve workflows to run** on it, and merges it once CI passes.
2. That merge changes `version` on `main`, which starts **Release** on its own. It tags the merge commit `vX.Y.Z` and runs **Deploy** with `qa` for that tag.
3. The user plays the build in QA.
4. **Deploy** with `prod`, on that tag, publishes it to Production.

Production only accepts the tag that matches `package.json`'s `version`, on `main`, after a successful QA publish of the same commit. Otherwise it stops with `release-tag-mismatch`, `release-not-on-main` or `qa-not-deployed`. Never start a Production publish, for example with `gh workflow run deploy.yml -f target=prod`, unless the user asks for that release by name. To roll back, the user publishes an earlier tag to Production; that doesn't roll back DataStores.

## Several places

A game with files in `places/` publishes them as one set: every destination first, then the start place, which is `krf.startPlace`. Every universe maps the same place names to its own place IDs, so a place's ID differs between Dev, QA and Production. Look up teleport destinations from game configuration keyed by `game.GameId`, never from one universe's hard-coded place ID.

If a publish fails partway, the output lists which places run the new build and which still run the old one. Report that to the user, fix the cause, and publish again. If publishing is locked with `publish-in-flight`, an earlier upload was never confirmed: tell the user to check the place's version history in Creator Dashboard before deleting the lock files the message names. Don't delete them yourself.

## Keys

- Never print, log or commit a key, and never write one into a tracked file. `.env` is Git-ignored; let the user create it.
- When a command fails with `missing-credential`, tell the user which variable to set. Never ask them to paste a key into the chat.

## What gets published

A publish builds from source, as `npm run build` does. Work done in Studio reaches Dev, QA or Production only after it has been synced back into `world/` and committed. If the user built something in Studio, check `git status` for `world/` before publishing. [world.md](docs/getting-started/world.md) explains syncback.
