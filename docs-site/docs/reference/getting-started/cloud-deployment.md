---
title: Cloud deployment
---

# Deploy a Full project to Roblox

You can build with `npm run build` and test in Studio before you set up Roblox Open Cloud. Cloud publishing takes the complete place from a Full project. For a Hybrid project, publish its Studio-owned place from Studio and continue to use Rojo for local code sync.

## Set up the Dev targets

In Creator Dashboard, select your group and create an experience for each developer who needs cloud testing. Create separate experiences for QA and Production. Record the universe ID and the place ID from each experience's Places tab. Pick a disposable Dev place for your first publish and verify that the target place is safe to replace. Keep this mapping in the game's `package.json` under `krf`.

```json
{
  "deployment": {
    "owner": { "kind": "group", "id": "123" },
    "developers": {
      "alex": { "universeId": "2001", "placeId": "3001" },
      "sam": { "universeId": "2002", "placeId": "3002" }
    },
    "qa": { "universeId": "2010", "placeId": "3010" },
    "production": { "universeId": "2020", "placeId": "3020" }
  }
}
```

Create a dedicated API key for each environment. In Creator Dashboard, add the `assets` API system and give it **Read** and **Write** for the group that owns your experiences. KRF publishes places through the Assets API, which treats each place as an asset. That permission covers every asset the group owns, so any environment's key can publish to any place in the group. KRF still publishes only to the target you select, and Production deploys still require a release tag that passed QA, but keep every key out of shared files and rotate one as soon as it may have leaked. Rotate developer keys when assignments change and rotate CI keys separately. [Roblox place publishing guide](https://create.roblox.com/docs/cloud/guides/usage-place-publishing) · [Roblox API key introspection](https://create.roblox.com/docs/cloud/auth/api-keys#introspect-api-keys)

Put the Dev key in `KRF_ROBLOX_DEV_KEY` in your Git-ignored project `.env` or export it from a credential manager. Shell values take precedence. Before publishing, Roblox confirms that each place belongs to its universe, that the universe belongs to your group and that the key has Assets read and write access. A private universe can omit its owner, so the result records `owner-unreported` and the publish itself fails if the key's group does not own the place. Anyone can select an assignment name with `--developer` or `KRF_DEVELOPER`. You can add QA and Production to the configuration after Dev setup.

```sh
npm run env:list -- --json
npm run deploy:dev -- --developer alex --verify-target --json
npm run deploy:dev -- --developer alex
npm run open:dev -- --developer alex
```

`env:list` shows the configured targets. `--verify-target` checks the credentials and target with Roblox without building or publishing. Deploy builds through the project's npm script. Use `npm run deploy:dev -- --allow-dirty` for local Dev experiments. `open:dev` prints the game's URL, or the target's optional `url` from the configuration.

## Deploy an experience with multiple places

Create a new Full project with `npm create krf@latest my-game -- --yes --places lobby,dungeon`. The first name becomes `krf.startPlace` in `package.json`. KRF finds each place by its Rojo file in `places/`. The template creates `places/lobby.project.json` and `places/dungeon.project.json`, each mapped to its own folder in `world/` and the shared `src/`. `npm run dev` opens the start place in Studio. To work on the dungeon instead, run `npm run dev -- --place dungeon`.

`npm run build` builds all the named binaries without opening Studio. Local development and builds work without deployment targets or Roblox credentials.

```json
{
  "krf": {
    "startPlace": "lobby",
    "deployment": {
        "owner": { "kind": "group", "id": "123" },
      "developers": {
        "alex": { "universeId": "2001", "places": { "lobby": "3001", "dungeon": "3002" } }
      },
      "qa": { "universeId": "2010", "places": { "lobby": "3010", "dungeon": "3011" } },
      "production": { "universeId": "2020", "places": { "lobby": "3020", "dungeon": "3021" } }
    }
  }
}
```

Create every place in each universe in Creator Dashboard and map the same logical names to the corresponding IDs. `startPlace` must match the universe's actual start place. Use `npm run open:dev -- --developer alex --place dungeon` to get a specific Dev place URL.

`npm run deploy:dev` builds and validates the full set before uploading. It publishes the destinations first and the start place last. Each publish creates its own Roblox revision. If a publish fails partway, the output shows which places are live with the new build, which still run their previous revision, and Roblox's reason for the failure. Fix the problem and deploy again. If Roblox never confirms an upload, krf-tools locks publishing for that universe and prints the lock files to delete once you have checked the place's version history in Creator Dashboard.

QA and Production publish every place in the set the same way. Put each universe's teleport destination IDs in game-owned configuration and look them up using `game.GameId`, so the same build runs in both universes.

## Release to QA and Production

A Full project generated with `--ci` has three workflows for this.

| Workflow | When it runs | What it does |
| --- | --- | --- |
| **Deploy** | You run it, choosing a branch or tag and `qa` or `prod` | Checks the project, builds that commit and publishes it to the QA or Production universe |
| **Release PR** | You run it with `patch`, `minor`, `major` or an exact version | Bumps `version` in `package.json` and opens a `chore(release): vX.Y.Z` pull request |
| **Release** | A merge to `main` changes `version` | Tags the merge commit `vX.Y.Z` and runs **Deploy** for that tag with `qa` |

Add the keys as repository secrets named `KRF_ROBLOX_QA_KEY` and `KRF_ROBLOX_PROD_KEY`. Each Deploy run only receives the key for the target you chose. In the repository's Actions settings, allow GitHub Actions to create pull requests so **Release PR** can open its pull request.

Any branch can go to QA, which is how you try a change in the QA universe before it is released. Production is stricter. A `prod` run must start from the tag that matches `package.json`, the tag must be on `main`, and a `qa` Deploy run must have succeeded for that commit. Otherwise it stops before building.

A release looks like this:

1. Run **Release PR**. On the pull request it opens, choose **Approve workflows to run**, wait for CI to pass, then merge it.
2. **Release** tags the merge commit and deploys it to QA.
3. Play the game in the QA universe.
4. When you want it live, run **Deploy** on the tag with `prod`. Nothing waits on a timer, so you choose when Production changes.

```sh
gh workflow run release-pr.yml -f to=minor
gh workflow run deploy.yml --ref v1.3.0 -f target=prod
```

GitHub holds CI on a pull request that Actions opens until someone with write access approves it, so choose **Approve workflows to run** on the release pull request before you merge. To roll Production back, run **Deploy** with `prod` on an earlier tag. Re-publishing a place does not roll back DataStores or external services.
