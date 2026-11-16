# create-krf

Creates a Roblox game project that uses [KRF](https://kevmp.github.io/KRF/).

```bash
npm create krf@latest
```

```bash
npx create-krf@latest my-game --yes
```

Requires Node.js 22.12 or newer. Nothing is installed globally: after creation, every project
task is an `npm run` script backed by the project's pinned `krf-tools` dependency.

## What this release creates

This release creates the project shell: `package.json` with the pinned tooling, `krf.project.json`
recording the chosen options and target versions, `README.md`, `.gitignore`, and the optional
CI workflow and agent instructions. It does not yet generate a Rojo project, Wally dependencies or
game code, so the shell cannot be built or played in Studio.

| Target | Version |
| --- | --- |
| KRF runtime (Wally) | `kevmp/krf@0.1.0` |
| Project tooling (npm) | `krf-tools@0.1.0` |

Templates ship inside this package; creating a project never downloads templates or KRF source.

## Options

Without `--yes`, an interactive terminal asks for every value not given as a flag. With `--yes`,
or without a terminal, missing values use the defaults below and nothing is asked.

| Flag | Values | Default |
| --- | --- | --- |
| `[project-name]` | Lowercase letters, digits, `-`, `_`, `.`; the last path segment becomes the project name | Asked; required without a terminal |
| `--mode` | `full`: Git and Rojo own the whole place. `hybrid`: Rojo owns code; Studio keeps world content | `full` |
| `--tooling` | `standard` or `minimal` | `standard` |
| `--ci` / `--no-ci` | Add a GitHub Actions workflow | `--ci` |
| `--agents` / `--no-agents` | Add `AGENTS.md` for AI coding agents | `--agents` |
| `--git` / `--no-git` | Run `git init` (skipped inside an existing repository) | `--git` |
| `--install` / `--skip-install` | Run `npm install` in the new project | `--install` |
| `-y`, `--yes` | Use defaults for every missing value; never prompt | |
| `-h`, `--help` / `-v`, `--version` | Show help or the creator version | |

These produce the same project:

```bash
npm create krf@latest
# Project name: my-game, then accept every default
```

```bash
npm create krf@latest my-game -- --yes
```

## Safety and exit codes

Every value is validated before anything is written. The target must not exist or must be an
empty directory; `..` segments and filesystem roots are refused. Files are written to a hidden
directory beside the target and renamed into place, so a failure leaves no partial project. If
`git init` or `npm install` fails afterwards, the complete project stays and the command reports
which step to rerun.

| Code | Meaning |
| --- | --- |
| `0` | Project created and every requested step succeeded. |
| `1` | Creation failed, or the project was created but a setup step failed. |
| `2` | Invalid arguments or values; nothing was written. |
| `130` | The wizard was cancelled; nothing was written. |

## Contributing

`create-krf` and `krf-tools` live in the KRF repository as npm workspaces. From the repository root:

```bash
npm run test:packages
```

```bash
npm run test:packages:integration
```

The integration test packs both packages, installs the creator from its tarball in an isolated
directory, creates a project through the installed `create-krf` command and runs that project's
`npm run project:info` against the packed `krf-tools`.

Templates live in `templates/`: `base` for every project, then `ci` and `agents` when selected.
`.ejs` files render with the project data and lose the suffix; a leading `_` in a name becomes
`.` because npm drops `.gitignore` from published packages. Project task logic belongs in
`krf-tools`, not in generated files.
