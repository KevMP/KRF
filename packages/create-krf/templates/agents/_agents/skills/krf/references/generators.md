# Generators

Create every KRF definition with its generator, then edit the file it writes. The generator writes a typed `--!strict` module with the right shape, puts it in the folder startup loads, checks its references and tells you what's left to do. A hand-written definition can look right and still never load.

This file is the full reference for every generator. The other references show one command each; come back here for every flag and default.

## Run a generator

```bash
npm run createAction -- --name Dash --recipe instant --cost Stamina=15 --requestable --yes --json
```

- `--yes` uses the defaults for anything you don't pass, and never prompts. Without it, a terminal wizard asks for each missing value.
- `--json` prints one result object to stdout. Diagnostics go to stderr.
- Quote any value with parentheses, `|` or spaces, such as `"Target:Array(F32,3)"` or `"Mode:Enum(Solo|Group)"`.

Use `--dry-run` with `--json` to see the files a command would create or edit without writing anything.

## Flags every generator takes

| Flag | Meaning |
| --- | --- |
| `--name <Name>` | PascalCase module name. Also the ID unless `--id` is given |
| `--id <id>` | The definition ID, or a Controller's key. A namespaced ID such as `Combat.Fireball` also nests the file, as `Actions/Combat/Fireball.luau` |
| `--output <path>` | Write the module somewhere else, relative to the project root. Startup may not load it there; read the result |
| `--dry-run` | Report the plan without writing |
| `--json` | Print one JSON result |
| `--yes`, `-y` | Use defaults and never prompt |

## Generate in dependency order

A definition that names another one, such as an Action with a Mana cost or a Tag that modifies WalkSpeed, needs that one to exist. The generator warns when it doesn't, and KRF rejects startup until it does. Create them in this order:

1. Properties.
2. Resources and Tags, which read Properties.
3. Controllers, which can depend on each other.
4. Actions, which reference Tags, Resources, Properties and other Actions.
5. Replication domains, Commands and Hints, which usually read Controllers.

The built-in Properties `WalkSpeed` and `JumpPower`, and the built-in Controllers `TagController`, `PropertyController`, `ResourceController` and `ActionController`, already exist.

## Read the result

Read `status` first:

| Status | Exit code | What to do |
| --- | --- | --- |
| `created` | 0 | The module is wired. Edit its behavior |
| `dry-run` | 0 | Nothing was written. `outcome` is the status a real run would get |
| `already-exists` | 3 | Nothing was overwritten. Edit the existing module instead |
| `created-not-loaded` | 4 | The module exists, but nothing loads it. Move it into the folder `next` names |
| `manual-wiring-required` | 5 | The module exists. Add the lines `manual` lists to the files it names |
| `error` | 1 or 2 | Nothing was written. Read `error.message` and `error.hint`, fix the flags and run it again |

Then act on the rest of the result:

| Field | Contains |
| --- | --- |
| `file` | The module to edit |
| `changes` | Every file created or edited |
| `manual` | Lines you must add by hand, with the file for each |
| `next` | Steps still needed, such as granting an Action, binding a key or filling in a stub |
| `warnings` | References to definitions that don't exist yet. Create them before starting the game |

Never run a generator again to fix a result. It doesn't overwrite or repair; a second run returns `already-exists`. Edit the files instead.

## Field types

Generators that declare network data, such as `--start-field`, `--state-field`, `--request-field` and `--payload-field`, take `Name:Type`. Repeat the flag for each field.

| Type | Example |
| --- | --- |
| `Boolean` | `Enabled:Boolean` |
| `U8`, `U16`, `U32`, `I8`, `I16`, `I32` | `Count:U8` |
| `F32`, `F64` | `Strength:F32` |
| `String(maxBytes)` | `"ItemId:String(32)"` |
| `Enum(A\|B)` | `"Mode:Enum(Solo\|Group)"` |
| `Optional(Type)` | `"Note:Optional(String(64))"` |
| `Array(Type,maxLength)` | `"Target:Array(F32,3)"` |
| `Map(KeyType,ValueType,maxEntries)` | `"Items:Map(String(32),U16,40)"` |

Flags can't declare a nested record. For one, generate the closest shape and edit the `KRF.Schema.Struct` in the module. See [replication.md](replication.md#pick-schema-types) for choosing types.

## createProperty

| Flag | Default | Meaning |
| --- | --- | --- |
| `--default <value>` | `0` | Base value on every Actor that has it |
| `--auto-assign` | off | Give it to every Actor |

```bash
npm run createProperty -- --name MaxStamina --default 100 --auto-assign --yes --json
```

Without `--auto-assign`, `next` tells you how to give it to an Actor. See [properties.md](properties.md).

## createResource

| Flag | Default | Meaning |
| --- | --- | --- |
| `--max <value \| Property>` | `100` | Maximum: a number, or a Property ID |
| `--min <value \| Property>` | `0` | Minimum: a number, or a Property ID |
| `--initial <value>` | The maximum | Starting value |
| `--regen <rate \| Property>` | None | Regeneration per second: a number, or a Property ID |
| `--visibility <visibility>` | `ServerOnly` | `ClientVisible` to show it to clients |
| `--no-auto-assign` | Assigned | Don't give it to every Actor |

```bash
npm run createResource -- --name Stamina --max MaxStamina --regen 5 --visibility ClientVisible --yes --json
```

The generator assigns Resources to every Actor unless you pass `--no-auto-assign`, although a hand-written definition defaults to not assigned. See [resources.md](resources.md), including cooldowns and charges.

## createTag

| Flag | Default | Meaning |
| --- | --- | --- |
| `--duration <seconds>` | Until removed | Default duration |
| `--duplicate-behavior <behavior>` | `Ignore` | `Ignore`, `Refresh` or `Stack` when applied again |
| `--max-stacks <count>` | No limit | Most instances a `Stack` Tag can have |
| `--tick-interval <seconds>` | None | Run `onTick` at this interval while active, and add its stub |
| `--property <Property:operation=value>` | None | A modifier, such as `WalkSpeed:multiply=0.5,min=4`. Operations are `set`, `add`, `multiply`, `min` and `max`. Repeatable |
| `--visibility <visibility>` | `ServerOnly` | `ClientVisible` to show it to clients |

```bash
npm run createTag -- --name Slowed --duration 3 --duplicate-behavior Refresh --property WalkSpeed:multiply=0.5 --visibility ClientVisible --yes --json
```

See [tags.md](tags.md).

## createController

| Flag | Default | Meaning |
| --- | --- | --- |
| `--depends-on <key>` | None | A Controller key it needs attached first. Repeatable |
| `--no-auto-attach` | Attached | Don't attach it to every Actor |

```bash
npm run createController -- --name Inventory --depends-on ResourceController --yes --json
```

See [actors-and-controllers.md](actors-and-controllers.md).

## createAction

| Flag | Default | Meaning |
| --- | --- | --- |
| `--recipe <recipe>` | `instant` | `instant`, `channel`, `held` or `toggle`. See [actions.md](actions.md#generate-it) |
| `--duration <seconds>` | `1` | How long a `channel` runs |
| `--auto-grant` | off | Grant it to every Actor |
| `--visibility <visibility>` | `ServerOnly`, or `ClientVisible` with `--requestable` | Whether clients see it running |
| `--required-tag <TagId>` | None | A Tag the caster must have. Repeatable |
| `--blocked-tag <TagId>` | None | A Tag that stops it starting. Repeatable |
| `--active-tag <TagId[:seconds]>` | None | A Tag held while it runs. Repeatable |
| `--applied-tag <TagId[:seconds]>` | None | A Tag that outlives it. Repeatable |
| `--requirement <Resource:...>` | None | A Resource condition, such as `Mana:min=10` or `Stamina:minPercent=0.5`. Keys are `min`, `max`, `minPercent` and `maxPercent`; percents are fractions from 0 to 1. Repeatable |
| `--cost <Resource=amount>` | None | A price paid at start, such as `Mana=20`, or `Mana:percent=0.1,multiplierProperty=CostScale`. Repeatable |
| `--lock <LockId>` | None | A lock held while it runs. Repeatable |
| `--interruptible-by <ActionId>` | None | An Action allowed to take its lock. Repeatable |
| `--hook <hook>` | None | An extra stub: `onCanStart`, `onStart`, `onStopRequested`, `onUpdate`, `onEnd`, `onInterrupt` or `canBeInterruptedBy`. Repeatable |
| `--requestable` | off | Let clients request it. Adds a request entry, and an input policy when needed |
| `--start-field <Name:Type>` | None | A field the client sends at start. Repeatable |
| `--stop-field <Name:Type>` | None | A field the client sends on release. Repeatable |
| `--client-stop` | off | Let a `channel` Action's client request a Stop. `held` and `toggle` always can |
| `--allow-input-interrupt` | off | Let the client interrupt its own activation |
| `--on-disconnect <policy>` | `Keep` | `Keep` or `Interrupt` when the player leaves. `held` always interrupts |

```bash
npm run createAction -- --name Fireball --recipe channel --duration 1.5 --cost Mana=20 --blocked-tag Stunned --active-tag Casting --lock Cast --requestable --start-field "Target:Array(F32,3)" --yes --json
```

`--start-field`, `--stop-field`, `--client-stop`, `--allow-input-interrupt` and `--on-disconnect` describe the client request, so they need `--requestable`. An `instant` Action can't take a Stop, so it rejects `--client-stop` and `--stop-field`.

The generator never binds a key. Follow `next`, and see [action-input.md](action-input.md) for binding and payloads. Without `--auto-grant`, `next` also tells you to grant it.

## createDomain

| Flag | Default | Meaning |
| --- | --- | --- |
| `--audience <audience>` | `Owner` | `Owner` or `All` |
| `--state-field <Name:Type>` | None | A field of the published state. Repeatable |
| `--event <EventId[(Name:Type,...)]>` | None | A published event, such as `"Hit(Damage:U16)"`. Adds the `observe` stub. Repeatable |
| `--observe` | off | Add the `observe` stub without declaring an event |

```bash
npm run createDomain -- --name Inventory --audience Owner --state-field "Items:Map(String(32),U16,40)" --event "ItemAdded(ItemId:String(32),Count:U16)" --yes --json
```

The generator defaults to `Owner`, although a hand-written domain without an audience is `All`. See [replication.md](replication.md).

## createCommand

| Flag | Default | Meaning |
| --- | --- | --- |
| `--target <target>` | `Actor` | `Actor` or `None` |
| `--request-field <Name:Type>` | None | A field the client sends. Repeatable |
| `--result-field <Name:Type>` | None | A field an accepted request returns. Repeatable |
| `--authorize <policy>` | `deny` | `deny`, `OwnerActor` or `AnyReadyClient` |

```bash
npm run createCommand -- --name BuyItem --request-field "ItemId:String(32)" --authorize OwnerActor --yes --json
```

The generated `handle` rejects every request with `NotImplemented`, and so does `authorize` with `deny`, until you write them. See [commands.md](commands.md).

## createHint

| Flag | Default | Meaning |
| --- | --- | --- |
| `--direction <direction>` | `ServerToClient` | `ServerToClient` or `ClientToServer` |
| `--target <target>` | `Actor` | `Actor` or `None` |
| `--mode <mode>` | `Pulse` | `Pulse` or `Latest` |
| `--payload-field <Name:Type>` | None | A payload field. Repeatable |
| `--authorize <policy>` | `deny` | `deny`, `OwnerActor` or `AnyReadyClient`. `ClientToServer` only |

```bash
npm run createHint -- --name ImpactEffect --target None --payload-field "Position:Array(F32,3)" --yes --json
```

A `ClientToServer` Hint also gets a `receive` stub. See [hints.md](hints.md).

## When the flags don't cover it

Generate the closest definition, then edit the module for the rest, such as a nested schema, a custom `authorize` or extra callbacks. Keep the file where the generator put it.

## Exact APIs

- [Project tools](docs/getting-started/project-tools.md#generate-a-definition): generator behavior, catalog folders, startup wiring and version checks.
