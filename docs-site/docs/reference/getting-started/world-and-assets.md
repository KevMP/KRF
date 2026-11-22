---
title: World and assets
---

# World and assets

You built part of your game in Roblox Studio and now want it in Git, so a teammate who clones the repository gets the same game from `npm run build`. In a Full project that happens when you save: while `npm run dev` is running, every save in Studio is captured into source files you can review and commit.

The direction matters. `npm run dev` and `npm run build` move source into Studio and into place files. A capture goes the other way, from the place you saved back into source. Under the hood it is Rojo's `syncback`, run by `npm run dev` after each save or by `npm run assets:syncback` when you ask.

## Save in Studio

In a Full project, `default.project.json` maps every service you build in to a folder under `world/`: Workspace, Lighting, MaterialService, ReplicatedFirst, ReplicatedStorage, ServerScriptService, ServerStorage, StarterGui, StarterPack, StarterPlayerScripts, StarterCharacterScripts, SoundService, Teams and TextChatService. Workspace starts with the Baseplate and SpawnLocation as JSON model files; the others start empty.

Run `npm run dev`, build in Studio as usual, and save with **File > Save to File** (Ctrl+S). The terminal running `dev` shows what the save changed:

```text
Studio saved my-game.rbxl; capturing it.
Captured settings into default.project.json:
  Lighting: Brightness, Technology
Captured 2 file changes:
  created world/ServerStorage/Sword.model.json
  changed world/Workspace/Arena.model.json
```

Review the changes with `git diff` when you're ready, and commit them. Captures never commit, push or publish anything. Pass `npm run dev -- --no-capture` to turn capturing off for a session.

Studio content becomes `.model.json` files, scripts become `.luau` files and folders become directories, so a moved part shows up as a changed `CFrame` in the diff. Settings of the services themselves, such as Lighting's Technology or Workspace's Gravity, go into `default.project.json`, which is where Rojo keeps them. References such as `Model.PrimaryPart` or `ObjectValue.Value` are saved as a pair of attributes, `Rojo_Id` on the target and `Rojo_Target_PrimaryPart` on the instance that points at it, named after the target's place path, like `Workspace/Arena/Floor`. Saving again without changes captures nothing.

While `dev` runs, a save is skipped if a captured file changed on disk since the last capture, for example because you edited it by hand or checked out another branch. Studio already has that change if it's connected to Rojo, so saving again captures normally. The first capture of a session copies the files it replaces to `build/krf/` when the project has no Git repository or has uncommitted changes in `world/`.

## Capture without dev

`npm run assets:syncback` captures a saved place once, without `dev`:

```bash
npm run assets:syncback
```

Without `--input`, it reads `<name>.rbxl` in the project root; pass another place with `-- --input path/to/place.rbxl`. `.rbxl` and `.rbxlx` both work. It reports the place and project it used, the captured trees and every created, changed or removed file, then tells you how to review them.

Because it runs on its own, it is stricter than a capture in `dev`: it refuses when the captured folders have uncommitted Git changes, so a capture never mixes with work you haven't reviewed. Commit or stash first, or pass `--allow-dirty` to capture anyway after copying the current files to `build/krf/`.

If you saved in Studio while `dev` wasn't running, run `npm run assets:syncback` before you start `dev` again. When Studio no longer has the place open, `dev` rebuilds `<name>.rbxl` from source, which replaces anything you saved but didn't capture.

## Know what gets captured

Code and installed packages are listed in `syncbackRules.ignoreTrees` in `default.project.json`, so a capture never rewrites `src/` or `Packages/` from the copy inside a saved place, which may be older than your files. Your own Studio scripts outside KRF's `Game` folders are captured like any other content. Workspace's Terrain and camera are never captured.

A saved place can leave out a service that has nothing in it. The capture then leaves that service's folder as it was and says so: `Not in the saved place, so left as they were: Teams`. Services that only exist while the game runs, such as Players, aren't mapped.

`npm run dev` keeps live sync from deleting what you build in Studio, because every mapped service is marked `$ignoreUnknownInstances`. Instances already captured are owned by their files, though, so if the Rojo plugin reconnects before a save is captured, it offers to reset changes made to them in Studio. Save first, or reject that change in the plugin.

## Hybrid projects

A Hybrid project keeps its world in the Studio place, and its live-sync project maps only code and packages. A capture there does nothing until you opt a part of the world into source. Let's say your arenas should be in Git while the rest of the map stays in Studio.

Add an `Arenas` folder to the tree in both `default.project.json`, which `npm run dev` serves and the capture reads, and `start-place.project.json`, which `npm run build` and new places use:

```json
"Workspace": {
	"$className": "Workspace",
	"Arenas": { "$path": "world/Workspace/Arenas" }
}
```

In `start-place.project.json`, Workspace already holds the starter Baseplate and SpawnLocation; add `Arenas` next to them. Then create the folder with an empty `world/Workspace/Arenas/.gitkeep` file, so Git keeps it while it has nothing else in it.

Run `npm run dev` so Rojo creates the empty Arenas folder in your place, then build your arena models inside it and save. `dev` captures the save, or run `npm run assets:syncback -- --input <name>.rbxl` yourself. Only what's inside Arenas is written; everything else in Workspace stays Studio-owned, and live sync leaves it alone. The command refuses to run if a captured tree is missing from `start-place.project.json`, because `npm run build` would then not include it.

Keep the mapped folder itself plain. In a Hybrid project the capture never edits the project files, so an attribute you set on Arenas itself stays in the place, and the capture lists it as not captured. Put that data on the models inside it.

## When a capture refuses

The command checks everything it can before it writes, and a refusal leaves your files as they were. It exits with a nonzero code and says what to fix.

| Message | What to do |
| --- | --- |
| `<place> does not exist` | Save the place from Studio, or pass the saved file with `--input` |
| `needs Rojo 7.7.1 or newer` | Set `rojo = "rojo-rbx/rojo@7.7.1"` in `rokit.toml`, then run `npm install` |
| `maps no world content` | A Hybrid project captures nothing until you opt a folder in, as shown above |
| `which holds code or installed packages` | A tree maps into `src/`, `Packages/` or another tool folder without being listed in `syncbackRules.ignoreTrees`; add it there |
| `which does not exist` | Create the mapped folder, or restore it; give an empty folder a `.gitkeep` file |
| `uncommitted changes` | Commit or stash your work in the captured folders first. `--allow-dirty` captures anyway after copying the current files to `build/krf/` |
| `outside the captured folders` | Rojo would write a file that isn't under a captured folder. Map that content to a folder under `world/`, and list any code it holds in `syncbackRules.ignoreTrees` |
| `is duplicated in the place file` | Two siblings under a mapped tree share a name; rename one in Studio and save |
| `present only in a project file` | The place lacks an instance the project declares. Check `--input`, or run `npm run dev` once so Rojo creates it |

Newer Studio builds save properties that the pinned Rojo doesn't know, so Rojo can't tell they're at their defaults. New projects list the ones we've seen, such as `SerializedOverrides`, in `syncbackRules.ignoreProperties`. If a captured file gains a property you never set, add its name there under `Instance` or under its class, and capture again.

A project without Git works too. The command copies the folders it is about to change to `build/krf/syncback-<time>/backup` first and lists every created, changed and removed file, so you can compare or restore them by hand. It never runs `git init`.

Pass `--dry-run` to see the files Rojo would rewrite or remove without writing anything. The list can name files whose content ends up unchanged after a real capture.

## What isn't covered yet

Terrain, unions and other CSG parts, MeshPart geometry and other content that is hard to round-trip haven't been tested and may not rebuild faithfully, so check them in the rebuilt place before you rely on them. Terrain is never captured. Captures follow saves, not every edit: an unsaved change in Studio isn't in your files yet. The Rojo plugin's experimental two-way mode is not part of this workflow.

## Reference hosted assets by name

Animations, images, meshes and audio live on Roblox and are used by asset ID. Instead of scattering those IDs through your code, list them once in `assets/manifest.json`:

```json
{
  "assets": [
    {
      "name": "FireballCast",
      "kind": "Animation",
      "id": 1234567890,
      "source": "assets/animations/FireballCast.rbxm"
    },
    { "name": "Theme", "kind": "Audio", "id": 9876543210, "owner": { "group": 4242 } }
  ]
}
```

Then run:

```bash
npm run assets:check -- --write
```

It records the SHA-256 of each source file in the manifest and writes `src/shared/GameAssets.luau`, a frozen table of content IDs that your code can require:

```lua
local GameAssets = require(ReplicatedStorage.Shared.GameAssets)

animation.AnimationId = GameAssets.FireballCast
```

| Field | Meaning |
| --- | --- |
| `name` | The logical name your code uses; a Luau identifier, unique in the manifest |
| `kind` | `Animation`, `Audio`, `Image` or `Mesh` |
| `id` | The numeric Roblox asset ID, without `rbxassetid://` |
| `source` | Optional path to the original file in the project, such as an exported `.rbxm` or `.png` |
| `sha256` | Recorded by `--write` when there is a `source`; leave it out yourself |
| `owner` | Optional `{ "user": <id> }` or `{ "group": <id> }`, for your own records |

`npm run assets:check` without `--write` changes nothing. It fails when a record is invalid, a name repeats, a source file is missing, a source file changed since its hash was recorded, or `GameAssets.luau` doesn't match the manifest. Generated CI workflows run it on every push; it passes when there is no manifest.

A changed hash means the file in Git is no longer the one you uploaded. Upload the new file, put its new ID in `id`, delete `sha256`, and run `npm run assets:check -- --write` to record the new hash. `--write` never overwrites a recorded hash for you.

The check is local. A valid ID only means the number is well formed; it doesn't mean the asset exists, that you uploaded the file it names, or that your account or group may use it. Studio loads an animation in Play only when the signed-in account can access it. Uploading assets, managing group permissions and keeping separate IDs per environment are not handled by these tools: upload through Studio or the Creator Hub and paste the ID into the manifest.

Keep the original files in Git next to the manifest. New projects mark `assets/**` as binary in `.gitattributes`, so line-ending conversion never changes their hashes. For large files, track `assets/**` with [Git LFS](https://git-lfs.com/).

## Options

| Option | Applies to |
| --- | --- |
| `--no-capture` | `dev`: don't capture when Studio saves the place |
| `--input <place>` | `assets:syncback`: the `.rbxl` or `.rbxlx` file saved from Studio; default `<name>.rbxl` |
| `--dry-run` | `assets:syncback`: list Rojo's planned writes and removals without writing |
| `--allow-dirty` | `assets:syncback`: capture even with uncommitted changes in the captured folders, after backing them up under `build/krf/` |
| `--write` | `assets:check`: record missing source hashes and regenerate `src/shared/GameAssets.luau` |

Both commands are wrappers around the Rojo pinned in `rokit.toml` and the manifest file, so they behave the same for you, your teammates and an agent running them without a terminal.
