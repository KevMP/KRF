# krf-tools

The project-generation library behind [`create-krf`](https://www.npmjs.com/package/create-krf).
Generated projects do not depend on it.

| Export | Purpose |
| --- | --- |
| `projectOptionsSchema`, `PROJECT_OPTION_DEFAULTS` | The Zod schema and defaults for project options. |
| `renderTemplates(roots, data)` | Renders template directories into memory with `mem-fs-editor`: `.ejs` files through EJS, other files byte for byte, `__key__` path segments from `data`, leading `_` to `.`. Later roots replace earlier files. |
| `writeNewDirectory(target, files)` | Writes a file set as a new directory through a staging directory and one rename; a failure leaves no files and never removes existing content. |
| `inspectTarget(target)` | Confirms a directory is missing or empty before writing. |
| `KrfToolError`, `ExitCode`, `formatError` | Stable error codes, hints and exit codes. |
