---
sidebar_position: 2.5
description: Generate typed KRF definition modules in a create-krf project with npm scripts.
---

# Definition Generators

Projects created with `create-krf` include npm scripts that write a typed, `--!strict` module for each kind of definition `KRF.Server.Init` accepts. Each catalog folder's `init.luau` loads every module beneath it, so a generated definition loads on the next build without a registration edit.

```bash
npm run createAction -- --name Fireball --yes
```

The scripts run the `krf-tools` version pinned in the project's `devDependencies`. They need no global install and never download templates.

## Scripts

| Script | Writes | `Server.Init` field |
| --- | --- | --- |
| `npm run createAction` | `src/server/Actions/<Name>.luau`, an Action factory | `actions` |
| `npm run createTag` | `src/server/Tags/<Name>.luau` | `tags` |
| `npm run createResource` | `src/server/Resources/<Name>.luau` | `resources` |
| `npm run createProperty` | `src/server/Properties/<Name>.luau` | `properties` |
| `npm run createController` | `src/server/Controllers/<Name>.luau` | `controllers` |
| `npm run createCommand` | `src/server/Commands/<Name>.luau` | `commands` |
| `npm run createHint` | `src/server/Hints/<Name>.luau` | `hints` |
| `npm run createDomain` | `src/server/ReplicationDomains/<Name>.luau` | `replicationDomains` |

The first time you create a Controller, Command, Hint or replication domain, the generator also creates that folder's `init.luau` loader and adds two lines to `src/server/Startup.server.luau`: a `require` for the loader and the matching `Server.Init` field. If `Startup.server.luau` already passes that field from another folder, new modules default to that folder.

Pass flags after `--`. Without `--yes`, an interactive terminal asks for the name and the kind's main choices that were not given as flags. With `--yes`, `--json`, or no terminal, nothing is asked and missing values use their defaults.

| Flag | Meaning |
| --- | --- |
| `--name <Name>` | PascalCase module and file name. Also the ID unless `--id` is given |
| `--id <id>` | The definition's ID, or the key for a Controller. A namespaced ID such as `Combat.Fireball` nests the default path: `src/server/Actions/Combat/Fireball.luau` |
| `--output <path>` | Module path relative to the project root, such as `src/server/Actions/Combat/Fireball.luau`. The file name is the module name |
| `--dry-run` | Report the planned files and edits without writing anything |
| `--json` | Print exactly one JSON result object to stdout |
| `-y`, `--yes` | Use defaults for every value not given and never prompt |

Run any script with `-- --help` for its full flag list.

## Definition options

Every option is a flag, and repeatable flags can be given more than once. Without `--yes`, the wizard asks for the same values one at a time, naming each definition field with a short note on what it does, such as `activeTags (Tags applied while the Action runs, removed when the Action ends)`. List questions show the IDs the project already defines and accept new ones; property questions show the registered Properties, including the built-in `WalkSpeed` and `JumpPower`; per-entry details such as a cost's amount or a requirement's minimum follow as their own questions, and percentages are entered from 0 to 100. Any value given as a flag is not asked again.

### Actions

| Flag | Writes | Default |
| --- | --- | --- |
| `--recipe instant\|channel\|held\|toggle` | The lifecycle hook that ends the Action; see below | `instant` |
| `--duration <seconds>` | How long the `channel` recipe runs | 1 |
| `--auto-grant` | `autoGrant = true` | Not granted |
| `--visibility ServerOnly\|ClientVisible` | `visibility` | ServerOnly; ClientVisible with `--requestable` |
| `--required-tag <TagId>` | `requiredTags` | |
| `--blocked-tag <TagId>` | `blockedTags` | |
| `--active-tag <TagId[:seconds]>` | `activeTags`, with an optional duration | |
| `--applied-tag <TagId[:seconds]>` | `appliedTags`, with an optional duration | |
| `--requirement <Resource:min=..,max=..,minPercent=..,maxPercent=..>` | `resourceRequirements` | |
| `--cost <Resource=amount>` or `--cost <Resource:percent=..,multiplierProperty=..>` | `costs`; give exactly one of `amount` and `percent` | |
| `--lock <LockId>` | `locks` | |
| `--interruptible-by <ActionId>` | `interruptibleBy` | |
| `--hook <hook>` | An empty stub for `onCanStart`, `onStart`, `onStopRequested`, `onUpdate`, `onEnd`, `onInterrupt` or `canBeInterruptedBy`, besides the recipe's own hook | |

All of these except `--recipe`, `--duration`, `--auto-grant` and `--visibility` can be repeated. Action recipes are lifecycle hooks, not Action kinds:

| Recipe | Generated behavior |
| --- | --- |
| `instant` | `onStart` ends the Action |
| `channel` | `onUpdate` accumulates time and ends the Action after `--duration` seconds |
| `held` | `onStopRequested` ends the Action, so it lasts until the player releases its input |
| `toggle` | `onStopRequested` ends the Action, so it lasts until the player presses its input again |

`--requestable` and the flags that describe the client's request are covered in [requestable Actions](#example-a-requestable-action).

### Tags, Resources, Properties and Controllers

| Script | Flag | Writes | Default |
| --- | --- | --- | --- |
| `createTag` | `--visibility` | `visibility` | ServerOnly |
| | `--duplicate-behavior Ignore\|Refresh\|Stack` | `duplicateBehavior` | Ignore |
| | `--max-stacks <count>` | `maxStacks`; needs `Stack` | No limit |
| | `--duration <seconds>` | `defaultDuration` | Lasts until removed |
| | `--tick-interval <seconds>` | `tickInterval` and an empty `onTick` | No ticking |
| | `--property <Property:operation=value,...>` | One `properties` entry; operations are `set`, `add`, `multiply`, `min` and `max`, and `set` stands alone. Repeatable, one flag per property | |
| `createResource` | `--max <value>` or `--max <Property>` | `max`, as a constant or a registered Property reference | 100 |
| | `--min <value>` or `--min <Property>` | `min` | 0 |
| | `--initial <value>` | `initialValue` | The maximum |
| | `--regen <rate>` or `--regen <Property>` | `regen.rate`, per second | No regeneration |
| | `--visibility`, `--no-auto-assign` | `visibility`, `autoAssign` | ServerOnly, auto-assigned |
| `createProperty` | `--default <value>` | `defaultBaseValue` | 0 |
| | `--auto-assign` | `autoAssign = true` | Not assigned |
| `createController` | `--depends-on <key>` | `dependsOn`; repeatable | |
| | `--no-auto-attach` | `autoAttach = false` | Attached to every Actor |

For example, `--property WalkSpeed:multiply=0.5,min=4` writes `WalkSpeed = { multiply = 0.5, min = 4 }`, and `--max MaxStamina` writes `max = { propertyName = "MaxStamina" }`.

A Tag modifier, Resource source or cost `multiplierProperty` names a registered [Property](./Property/property-registry); create it with `createProperty`. The generator warns when a referenced Property is not defined, and KRF rejects startup until it is.

### Commands, Hints and replication domains

| Script | Flag | Writes | Default |
| --- | --- | --- | --- |
| `createCommand` | `--target Actor\|None` | `target` | Actor |
| | `--request-field <Name:Type>`, `--result-field <Name:Type>` | The `request` and `result` schemas | No payload |
| | `--authorize deny\|OwnerActor\|AnyReadyClient` | `authorize` | `deny` |
| `createHint` | `--direction ServerToClient\|ClientToServer`, `--target Actor\|None`, `--mode Pulse\|Latest` | `direction`, `target`, `mode` | ServerToClient, Actor, Pulse |
| | `--payload-field <Name:Type>` | The `payload` schema | Empty |
| | `--authorize deny\|OwnerActor\|AnyReadyClient` | `authorize`, for ClientToServer Hints | `deny` |
| `createDomain` | `--audience Owner\|All` | `audience` | Owner |
| | `--state-field <Name:Type>` | The `state` schema, and a `snapshot` returning a zero value for each required field | Empty |
| | `--event <EventId>` or `--event "EventId(Name:Type,...)"` | One `events` entry and its payload schema; adds an `observe` stub | |
| | `--observe` | An `observe` stub | |

Schema fields are `Name:Type`, and every field flag can be repeated. The types are `Boolean`, `U8`, `U16`, `U32`, `I8`, `I16`, `I32`, `F32`, `F64`, `String(maxBytes)`, `Enum(A|B)`, `Optional(Type)`, `Array(Type,maxLength)` and `Map(KeyType,ValueType,maxEntries)`, and they nest: `Targets:Array(Optional(U32),8)`. They become [`KRF.Schema`](./Networking/schemas) calls.

`--authorize deny` writes a stub that returns `false, "NotImplemented"`. `OwnerActor` and `AnyReadyClient` use KRF's `CommandAuthorization` and `HintAuthorization` policies; `OwnerActor` needs `--target Actor`. A Command's `handle` and a client-to-server Hint's `receive` are always stubs: `handle` rejects with `"NotImplemented"` until you write it. Server-to-client Hints have no callbacks.

The generator warns, without failing, when an Action names a Tag, Resource or Action, or a Controller depends on a key, that it cannot find in the project. KRF rejects startup until the reference exists.

## Example: Fireball

```bash
npm run createAction -- --name Fireball --recipe channel --duration 2 --cost Energy=10 --yes
```

This writes only `src/server/Actions/Fireball.luau`:

```lua title="src/server/Actions/Fireball.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local DURATION: number = 2

function Fireball(): KRF.ActionDefinition
	local elapsed: number = 0

	return {
		id = "Fireball",
		visibility = "ServerOnly",
		costs = { Energy = 10 },
		onUpdate = function(context: KRF.ActionExecutionContext, deltaTime: number): ()
			elapsed += deltaTime

			if elapsed >= DURATION then
				context:End()
			end
		end,
	}
end

return Fireball
```

`src/server/Actions/init.luau` already returns every module in its folder, and `Startup.server.luau` passes that list to `Server.Init` as `actions`. Run `npm run check` and `npm run build`, then put the Action's behavior in its hooks. The factory runs once per Action instance, so `elapsed` belongs to one cast. The Action is not granted to anyone yet: grant it with [`ActionController:SetGrants`](./Action/action-grants), or generate it with `--auto-grant`.

## Example: a requestable Action

```bash
npm run createAction -- --name Guard --recipe held --requestable --auto-grant --stop-field "Direction:Array(F32,3)" --yes
```

Clients may only request Actions declared in the [Action request](./Action/action-requests) map that both `Server.Init` and `Client.Init` read. In the starter project that map is the `src/shared/ActionRequests` folder: its `init.luau` merges every module beneath it, and each module returns the entries for one Action. `--requestable` writes `src/shared/ActionRequests/Guard.luau` and defaults the Action to ClientVisible; a requestable Action can stay `--visibility ServerOnly`, since requesting is not the same as seeing it:

```lua title="src/shared/ActionRequests/Guard.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Guard: KRF.ActionRequestSchemas = {
	Guard = {
		stop = {
			parameters = KRF.Schema.Struct({
				Direction = KRF.Schema.Array(KRF.Schema.F32, 3),
			}),
		},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
}

return Guard
```

A `held` Action always gets a Stop path that requires the player to release the input, and a module in `src/client/ActionInputPolicies` declaring its `WhileDown` [input policy](./Action/action-input). A `toggle` Action gets a Stop path without the release requirement and a `Toggle` policy, so the first press starts it and the next press asks to stop it. The policy folder merges its modules the same way. Declaring one ID in two modules stops startup with an error naming it.

When input starts or releases the Action, its policy supplies the parameters. So an Action with `--start-field`, or a held or toggle Action with `--stop-field`, also gets `startParameters` or `stopParameters` producers in its policy module. They return a payload that matches the schema, with every required field at its zero value, so startup accepts the policy; replace those values with what your input should send.

| Flag | Writes | Default |
| --- | --- | --- |
| `--requestable` | The request module | Not requestable |
| `--start-field <Name:Type>` | `start`, the parameters the client sends with a request | No parameters |
| `--client-stop` | `stop = {}`, so the client may request a Stop, and an `onStopRequested` stub. A Stop does not end the Action by itself; call `context:End()` there if it should. The `instant` recipe ends in `onStart` before a Stop can arrive, so it rejects this flag and `--stop-field` | Only for `held` and `toggle` |
| `--stop-field <Name:Type>` | `stop.parameters` | No parameters |
| `--allow-input-interrupt` | `allowInputInterrupt = true` | Only for `held`, and for `toggle` with `--stop-field` |
| `--on-disconnect Keep\|Interrupt` | `onDisconnect = "Interrupt"` when `Interrupt` | `Keep`; always `Interrupt` for `held` |

Input bindings are game code, so the generator does not change them. In the starter project, keys bind to ability slots, and `src/client/Controls/Loadout.luau` decides which Action each slot triggers. Call `Loadout.Equip("AbilitySlot1", "Guard")` to put Guard in the F slot, or add a slot in `src/client/Controls/Keybinds.luau` and to `SLOTS` in `Loadout.luau`.

## Results

| Status | Exit code | Meaning |
| --- | --- | --- |
| `created` | 0 | The definition loads on the next build |
| `dry-run` | 0 | Nothing was written; `outcome` holds the status a real run would report |
| `already-exists` | 3 | The module file already exists. Nothing was written |
| `created-not-loaded` | 4 | The file was written, but no loader that `Startup.server.luau` passes to `Server.Init` reaches it |
| `manual-wiring-required` | 5 | The file was written, but the generator could not safely wire it: `Startup.server.luau` or a folder's loader was changed |
| Invalid arguments | 2 | Nothing was written |
| Other errors | 1 | Nothing was written |
| Cancelled | 130 | Nothing was written |

With `--json`, stdout holds one object with `status`, `kind`, `name`, `id`, `file`, `changes`, `manual`, `next` and `warnings`, or `status: "error"` with an `error` object holding `code`, `message` and `hint`. Diagnostics go to stderr. Use `npm run --silent` so npm does not print its script banner before the JSON:

```bash
npm run --silent createTag -- --name Stunned --yes --json
```

## Safety and recovery

The generator validates every name, ID, path and option and plans every file before it writes. It never overwrites a file, and it refuses an ID that another module in the catalog already defines, a path that differs from an existing one only by case, a module whose Rojo name another file or folder already uses, and a path inside another catalog's folder. If a write fails, it removes the files it created and restores every file it edited.

The only existing file it ever edits is `Startup.server.luau`, the first time a catalog folder is created, and only while the part it changes keeps the starter project's shape: one `KRF.Server.Init({ ... })` call whose fields are plain `field = Name,` lines, and one block of `local Name = require(...)` lines. Request and policy entries are new modules, written only while their folder's `init.luau` still merges its descendants. If an Action's request is already declared in another module, the generator leaves it alone and warns. Anything it cannot wire safely is left byte-for-byte unchanged, and the result is `manual-wiring-required`, listing the exact lines to add and where.

After a partial result, add the reported lines by hand, or move a `created-not-loaded` module under its catalog's folder. Do not rerun the same command: the module already exists, so a rerun reports `already-exists` and changes nothing. A rerun never adds a second module, `require` or request entry.

## KRF version

Each `krf-tools` release generates code for specific `kevmp/krf` releases. The generator reads the installed version from `wally.lock`, or the exact pin in `wally.toml` before the first install. When the project uses a KRF release it does not support, it writes nothing and names the `krf-tools` upgrade to install.
