# Generators

Create every KRF definition with its generator. The generator writes a typed module with the right shape and wires it into startup, and its result tells you whether anything is left to do by hand. A hand-written definition can look right and still never load.

| Definition | Script |
| --- | --- |
| Action | `npm run createAction` |
| Tag | `npm run createTag` |
| Resource | `npm run createResource` |
| Property | `npm run createProperty` |
| Controller | `npm run createController` |
| Replication domain | `npm run createDomain` |
| Command | `npm run createCommand` |
| Hint | `npm run createHint` |

## Run a generator

Pass the name, every flag the definition needs, `--yes` so the generator doesn't prompt, and `--json` to read the result:

```bash
npm run --silent createAction -- --name Dash --requestable --yes --json
```

Run a script with `--help` to see its options, such as Action recipes and request payload fields.

## Read the result

Read `status` before doing anything else:

- `created`: the module is wired. Edit its behavior.
- `already-exists`: nothing was overwritten. Edit the existing module instead of generating again.
- `created-not-loaded` or `manual-wiring-required`: the module exists but isn't loaded yet. Make the changes the result lists. Running the generator again won't fix it.

If a generator's options don't cover what you need, generate the closest definition and edit it.

For every option and status, see [Project tools](docs/getting-started/project-tools.md#generate-a-definition).
