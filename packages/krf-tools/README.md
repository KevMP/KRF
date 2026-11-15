# krf-tools

Project-local tooling for Roblox games created by
[`create-krf`](https://www.npmjs.com/package/create-krf). Each project pins an exact version as a
dev dependency and runs it through npm scripts:

```bash
npm run project:info
```

Use the scripts in your project's `package.json`. The `krf-tools` executable behind them is an
implementation detail and needs no global install.

## Commands

| Command | Script | Purpose |
| --- | --- | --- |
| `krf-tools info [--json]` | `npm run project:info` | Validates `krf.project.json` and prints the project's options and target versions. Fails if the installed `krf-tools` differs from the pinned version. |

A command this version does not provide fails with exit code `2` and lists the available
commands. Exit code `1` reports a project problem with a hint for fixing it.

## Project metadata

`krf.project.json` records how a project was created:

| Field | Contents |
| --- | --- |
| `metadataVersion` | Format version, currently `1`. |
| `name` | Project name. |
| `options` | `mode` (`full` or `hybrid`), `tooling` (`standard` or `minimal`), `ci` and `agents`. |
| `creator`, `template` | The `create-krf` version that generated the project and its templates. |
| `runtime` | The KRF Wally package and version the templates target. |
| `tooling` | The `krf-tools` version the project pins. |

## Library API

`create-krf` and future project commands share these exports:

| Export | Purpose |
| --- | --- |
| `projectOptionsSchema`, `PROJECT_OPTION_DEFAULTS` | The Zod schema and defaults for generated-output options. |
| `projectMetadataSchema`, `readProjectMetadata`, `serializeProjectMetadata` | Validate, read and write `krf.project.json` with stable key order. |
| `renderTemplates(roots, data)` | Renders template directories into memory with `mem-fs-editor`: `.ejs` files through EJS, other files byte for byte, `__key__` path segments from `data`, leading `_` to `.`. Later roots replace earlier files. |
| `writeNewDirectory(target, files)` | Writes a file set as a new directory through a staging directory and one rename; a failure leaves no files and never removes existing content. |
| `KrfToolError`, `ExitCode`, `formatError` | Stable error codes, hints and exit codes. |

`mem-fs-editor` renders and stages files in memory; its `commit()` writes file by file without
rollback, so `writeNewDirectory` performs the write. `node-plop` was not adopted: its add/modify
actions would add a second template language (Handlebars) without making safe partial-edit
handling simpler.
