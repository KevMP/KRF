---
title: World
---

# World

You built part of your game in Roblox Studio and now want it in Git, so a teammate who clones the repository gets the same game from `npm run build`. In a Full project that happens when you save: while `npm run dev` is running, every save in Studio is synced back into source files you can review and commit.

The direction matters. `npm run dev` and `npm run build` move source into Studio and into place files. Syncback goes the other way, from the place you saved back into source. It is Rojo's `rojo syncback`, run by `npm run dev` after each save or by `npm run world:syncback` when you ask.

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

Review the changes with `git diff` when you're ready, and commit them. Syncback never commits, pushes or publishes anything. Pass `npm run dev -- --no-syncback` to turn it off for a session.

Studio content becomes `.model.json` files, scripts become `.luau` files and folders become directories, so a moved part shows up as a changed `CFrame` in the diff. Settings of the services themselves, such as Lighting's Technology or Workspace's Gravity, go into `default.project.json`, which is where Rojo keeps them. References such as `Model.PrimaryPart` or `ObjectValue.Value` are saved as a pair of attributes, `Rojo_Id` on the target and `Rojo_Target_PrimaryPart` on the instance that points at it, named after the target's place path, like `Workspace/Arena/Floor`. Saving again without changes captures nothing.

While `dev` runs, a save is skipped if a captured file changed on disk since the last capture, for example because you edited it by hand or checked out another branch. Studio already has that change if it's connected to Rojo, so saving again captures normally. The first capture of a session copies the files it replaces to `build/krf/` when the project has no Git repository or has uncommitted changes in `world/`.

## Sync back without dev

`npm run world:syncback` syncs a saved place back once, without `dev`:

```bash
npm run world:syncback
```

Without `--input`, it reads `<name>.rbxl` in the project root; pass another place with `-- --input path/to/place.rbxl`. `.rbxl` and `.rbxlx` both work. It reports the place and project it used, the captured trees and every created, changed or removed file, then tells you how to review them.

Because it runs on its own, it is stricter than a capture in `dev`: it refuses when the captured folders have uncommitted Git changes, so a capture never mixes with work you haven't reviewed. Commit or stash first, or pass `--allow-dirty` to capture anyway after copying the current files to `build/krf/`.

If you saved in Studio while `dev` wasn't running, run `npm run world:syncback` before you start `dev` again. When Studio no longer has the place open, `dev` rebuilds `<name>.rbxl` from source, which replaces anything you saved but didn't capture.

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

Run `npm run dev` so Rojo creates the empty Arenas folder in your place, then build your arena models inside it and save. `dev` captures the save, or run `npm run world:syncback -- --input <name>.rbxl` yourself. Only what's inside Arenas is written; everything else in Workspace stays Studio-owned, and live sync leaves it alone. The command refuses to run if a captured tree is missing from `start-place.project.json`, because `npm run build` would then not include it.

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

## Options

| Option | Applies to |
| --- | --- |
| `--no-syncback` | `dev`: don't sync back when Studio saves the place |
| `--input <place>` | `world:syncback`: the `.rbxl` or `.rbxlx` file saved from Studio; default `<name>.rbxl` |
| `--dry-run` | `world:syncback`: list Rojo's planned writes and removals without writing |
| `--allow-dirty` | `world:syncback`: capture even with uncommitted changes in the captured folders, after backing them up under `build/krf/` |

Both commands are wrappers around the Rojo pinned in `rokit.toml`, so they behave the same for you, your teammates and an agent running them without a terminal.
