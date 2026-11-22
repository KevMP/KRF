---
title: World and assets
---

# World and assets

You built part of your map in Roblox Studio and now want it in Git, so a teammate who clones the repository gets the same world from `npm run build`. `npm run assets:syncback` does that: it reads a place you saved from Studio and writes the parts of it your Rojo project maps into source files you can review and commit.

The direction matters. `npm run dev` and `npm run build` move source into Studio and into place files. `assets:syncback` goes the other way, from a saved place back into source, and only when you run it. Nothing syncs from Studio to your files on its own.

## Capture the world from Studio

In a Full project, `default.project.json` maps Workspace to the `world/Workspace` folder, which starts with the Baseplate and SpawnLocation as JSON model files. Build in Studio as usual, then save the place with **File > Save to File** (Ctrl+S) over the `<name>.rbxl` that `npm run dev` opened. Then capture it:

```bash
npm run assets:syncback
```

Without `--input`, the command reads `<name>.rbxl` in the project root. Pass another saved place with `npm run assets:syncback -- --input path/to/place.rbxl`; `.rbxl` and `.rbxlx` both work.

Capture before you run `npm run dev` again. When Studio no longer has the place open, a Full `dev` run rebuilds `<name>.rbxl` from source, which replaces anything you saved but didn't capture.

The command tells you which place and project it used, which trees it captured and which files it created, changed or removed:

```text
Capturing my-game.rbxl into default.project.json (Full project).
Captured trees:
  Workspace -> world/Workspace
Never captured: ReplicatedStorage/Packages, ReplicatedStorage/Shared, ServerScriptService/Game, StarterPlayer/StarterPlayerScripts/Game, Workspace/Terrain.
Anything else in the place stays only in the place file.
Captured 1 file change:
  created world/Workspace/Arena.model.json
Review with git status -- world/Workspace and git diff -- world/Workspace, then commit. Nothing was committed.
Rebuild from source with npm run build to check the result.
```

Review the diff, commit it, and run `npm run build` to see the world come back from source. The command never commits, pushes or publishes anything.

New Parts, Models, lights, effects and GUIs are written as `.model.json` files, so a moved part shows up as a changed `CFrame` in the diff. Folders become directories. References such as `Model.PrimaryPart` or `ObjectValue.Value` are saved as a pair of attributes, `Rojo_Id` on the target and `Rojo_Target_PrimaryPart` on the instance that points at it, named after the target's place path, like `Workspace/Arena/Floor`. Capturing the same saved place twice changes nothing the second time.

## Know what gets captured

Only instances under a tree that the project maps to a folder or model file are captured. Code and installed packages are listed in `syncbackRules.ignoreTrees` in `default.project.json`, so a capture never rewrites `src/` or `Packages/` from the copy inside a saved place, which may be older than your files. Workspace's Terrain is ignored too.

Everything else in the place, such as Lighting settings, other services or the properties of Workspace itself, stays only in the place file. A fresh clone does not get it from `npm run build`. Rojo would store the properties of services and other instances that `default.project.json` declares in that file, so the capture keeps the project file exactly as it was and lists those values instead, such as `Workspace: Gravity`. Set them in `default.project.json` yourself if they belong in source. To keep more of the place in source, map it the same way Workspace is mapped and capture again; the tested baseline covers content inside Workspace.

`npm run dev` keeps live sync from deleting what you build in Studio before you capture it, because Workspace is marked `$ignoreUnknownInstances`. Instances you have already captured are owned by their files, though, so when the Rojo plugin reconnects it offers to reset changes made to them in Studio. Capture first, or reject that change in the plugin.

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

Run `npm run dev` once so Rojo creates the empty Arenas folder in your place. Build your arena models inside it, save, and run `npm run assets:syncback -- --input <name>.rbxl`. Only what's inside Arenas is written; everything else in Workspace stays Studio-owned, and live sync leaves it alone. The command refuses to run if a captured tree is missing from `start-place.project.json`, because `npm run build` would then not include it.

Keep the mapped folder itself plain. Arenas is declared in the project file, so an attribute you set on it in Studio stays in the place, and the capture lists it as not captured. Put that data on the models inside it.

## When a capture refuses

The command checks everything it can before it writes, and a refusal leaves your files as they were. It exits with a nonzero code and says what to fix.

| Message | What to do |
| --- | --- |
| `<place> does not exist` | Save the place from Studio, or pass the saved file with `--input` |
| `needs Rojo 7.7.1 or newer` | Set `rojo = "rojo-rbx/rojo@7.7.1"` in `rokit.toml`, then run `npm install` |
| `maps no world content` | Map a folder as shown above; a Hybrid project has none until you opt one in |
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

Terrain, unions and other CSG parts, MeshPart geometry and other content that is hard to round-trip haven't been tested and may not rebuild faithfully, so check them in the rebuilt place before you rely on them. Terrain is never captured. There is no automatic two-way sync from Studio to your files; the Rojo plugin's experimental two-way mode is not part of this workflow.

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
| `--input <place>` | `assets:syncback`: the `.rbxl` or `.rbxlx` file saved from Studio; default `<name>.rbxl` |
| `--dry-run` | `assets:syncback`: list Rojo's planned writes and removals without writing |
| `--allow-dirty` | `assets:syncback`: capture even with uncommitted changes in the captured folders, after backing them up under `build/krf/` |
| `--write` | `assets:check`: record missing source hashes and regenerate `src/shared/GameAssets.luau` |

Both commands are wrappers around the Rojo pinned in `rokit.toml` and the manifest file, so they behave the same for you, your teammates and an agent running them without a terminal.
