# @kevmp/krf-tools

Project tooling for KRF games. It renders the templates behind
[`create-krf`](https://www.npmjs.com/package/create-krf), and its `krf-tools` executable runs the
local development workflow and definition generators in every generated project. Projects pin it as an exact `devDependency` and
call it only through their npm scripts:

```bash
npm run createAction -- --name Fireball --yes
```

See [Project tools](https://kevmp.github.io/KRF/reference/getting-started/project-tools#work-on-the-game) for `npm run dev`, `npm test` and
`npm run test:studio`, and [Generate a definition](https://kevmp.github.io/KRF/reference/getting-started/project-tools#generate-a-definition) for the
`create*` scripts, their options, result statuses and exit codes. Each release generates code for the `kevmp/krf` versions
in `SUPPORTED_KRF_VERSIONS`.

| Export | Purpose |
| --- | --- |
| `runGenerator(argv, io)` | Runs `krf-tools create <kind>` and returns its exit code. |
| `runWorkflow(argv, io)`, `WORKFLOW_COMMANDS` | Runs `krf-tools dev`, `test`, `test-studio` or `sourcemap` and returns its exit code. |
| `runWorld(argv, io)`, `WORLD_COMMAND`, `WORLD_SCRIPTS` | Runs `krf-tools world syncback`, and the `world:*` npm scripts a project declares. |
| `DEFINITION_SCRIPTS` | The generator npm scripts a project declares, such as `createAction: "krf-tools create action"`. |
| `KRF_RUNTIME`, `SUPPORTED_KRF_VERSIONS`, `TEST_PACKAGES`, `TOOLS_PACKAGE`, `TOOLS_VERSION` | The KRF release new projects install, the releases the generators support, the Jest Wally packages `npm test` runs, and this package's name and version. |
| `projectOptionsSchema`, `PROJECT_OPTION_DEFAULTS` | The Zod schema and defaults for project options. |
| `renderTemplates(roots, data)` | Renders template directories into memory with `mem-fs-editor`: `.ejs` files through EJS, other files byte for byte, `__key__` path segments from `data`, leading `_` to `.`. Later roots replace earlier files. |
| `renderTemplate(file, data)` | Renders one EJS template to a string. |
| `writeNewDirectory(target, files)` | Writes a file set as a new directory through a staging directory and one rename; a failure leaves no files and never removes existing content. |
| `applyProjectChanges(root, changes)` | Creates new files and edits existing ones inside a project as one unit. New files must not exist, and edited files must still hold their expected bytes; a failure removes the created files and directories and restores every edited file. |
| `inspectTarget(target)` | Confirms a directory is missing or empty before writing. |
| `KrfToolError`, `ExitCode`, `formatError` | Stable error codes, hints and exit codes. |

The generator lives in `src/generate/`: `request.js` normalizes flags and wizard answers into one
request, `schema.js` parses and renders `KRF.Schema` field types, `plan.js` turns a request into
new modules, the recognized `Startup.server.luau` edit and a status, `startup.js` recognizes and
edits `Startup.server.luau`, `prompts.js` is the wizard, and `cli.js` runs the plan through
`applyProjectChanges`. Definition templates live in `templates/definitions/`.

The workflow lives in `src/workflow/`: `project.js` reads the project and derives test places,
`tools.js` runs the pinned Rokit tools, `rojo.js` starts `rojo serve` and waits for its port,
`studio.js` finds Roblox Studio, opens places and runs Studio scripts, `dev.js` is `npm run dev`,
`tests.js` is `npm test` and `npm run test:studio`, and `cli.js` parses their options. The Studio
scripts they inject live in `templates/studio/`.

The world syncback commands live in `src/world/`: `scope.js` reads which project trees a capture
may write and checks they never include code or packages, `capture.js` runs one `rojo syncback`
against a derived project under `build/krf/`, skipping services the saved place leaves out, then
normalizes the result, `declared.js` merges the settings Rojo records for declared instances into
`default.project.json`, `normalize.js` and `json.js` keep captured JSON models stable between
captures, `syncback.js` is `npm run world:syncback` with its Git guard and report, `watch.js`
captures each Studio save during `npm run dev`, `git.js` reads the working tree, and `cli.js` parses
their options. See [World](https://kevmp.github.io/KRF/reference/getting-started/world).
