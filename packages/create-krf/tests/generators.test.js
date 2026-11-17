import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runGenerator, writeNewDirectory } from "krf-tools";

import { buildProjectFiles } from "../src/create.js";

const CANCEL = Symbol("cancel");
const NOT_LISTED = "\u0000other";

const STARTUP = "src/server/Startup.server.luau";
const REQUESTS = "src/shared/ActionRequests";
const POLICIES = "src/client/ActionInputPolicies";

const EVERY_KIND = [
	["tag", "--name", "Stunned", "--duration", "2"],
	["resource", "--name", "Stamina", "--max", "50"],
	["action", "--name", "Fireball", "--requestable", "--auto-grant", "--blocked-tag", "Stunned", "--cost", "Stamina=10"],
	["action", "--name", "Guard", "--recipe", "held", "--requestable"],
	["action", "--id", "Combat.Meditate", "--recipe", "channel", "--duration", "0.5"],
	["controller", "--name", "Cooldowns", "--depends-on", "ResourceController"],
	["command", "--name", "CastSpell"],
	["hint", "--name", "ImpactFx"],
	["hint", "--name", "Ping", "--direction", "ClientToServer"],
	["domain", "--name", "ComboState"],
];

function newProject(t, mode = "full") {
	const parent = fs.mkdtempSync(path.join(os.tmpdir(), "krf-generate-"));
	t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
	const root = path.join(parent, "my-game");
	writeNewDirectory(root, buildProjectFiles({ target: root, name: "my-game", options: { mode, ci: false }, git: false }));
	return root;
}

function readTree(root) {
	const files = {};
	for (const entry of fs.readdirSync(root, { recursive: true, withFileTypes: true })) {
		if (!entry.isFile()) continue;
		const full = path.join(entry.parentPath, entry.name);
		files[path.relative(root, full).split(path.sep).join("/")] = fs.readFileSync(full, "utf8");
	}
	return files;
}

function source(root) {
	return Object.fromEntries(Object.entries(readTree(root)).filter(([file]) => file.startsWith("src/")));
}

function changedFiles(before, after) {
	return [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((file) => before[file] !== after[file]).sort();
}

function scriptedPrompts(answers) {
	const asked = [];
	const answer = (options) => {
		asked.push(options.message);
		if (!(options.message in answers)) throw new Error(`Unexpected prompt: ${options.message}`);
		const value = Array.isArray(answers[options.message]) ? answers[options.message].shift() : answers[options.message];
		if (value === undefined) throw new Error(`No answer left for: ${options.message}`);
		if (options.validate && value !== CANCEL) {
			const problem = options.validate(value);
			if (problem) throw new Error(`Validation failed: ${problem}`);
		}
		return Promise.resolve(value);
	};
	return { asked, prompts: { intro() {}, text: answer, select: answer, confirm: answer, multiselect: answer, isCancel: (value) => value === CANCEL } };
}

async function generate(root, argv, options = {}) {
	let stdout = "";
	let stderr = "";
	const code = await runGenerator(["create", ...argv], {
		cwd: options.cwd ?? root,
		interactive: options.prompts !== undefined,
		prompts: options.prompts,
		stdout: (text) => (stdout += text),
		stderr: (text) => (stderr += text),
	});
	return { code, stdout, stderr, json: argv.includes("--json") ? JSON.parse(stdout) : undefined };
}

test("createAction --name Fireball --yes writes one typed factory that the Actions loader already loads", async (t) => {
	const root = newProject(t);
	const before = readTree(root);
	const result = await generate(root, ["action", "--name", "Fireball", "--yes"]);
	assert.equal(result.code, 0, result.stderr);

	const after = readTree(root);
	assert.deepEqual(changedFiles(before, after), ["src/server/Actions/Fireball.luau"]);
	assert.equal(
		after["src/server/Actions/Fireball.luau"],
		`--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

function Fireball(): KRF.ActionDefinition
	return {
		id = "Fireball",
		visibility = "ServerOnly",
		onStart = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end

return Fireball
`,
	);
	assert.match(result.stdout, /^Created src\/server\/Actions\/Fireball\.luau\. It loads on the next build\.$/m);
	assert.match(result.stdout, /Fireball is not auto-granted/);
	assert.equal(result.stderr, "");
});

test("first use of each catalog creates its loader and wires Startup once; later definitions only add a file", async (t) => {
	const root = newProject(t);
	for (const argv of EVERY_KIND) {
		const result = await generate(root, [...argv, "--yes"]);
		assert.equal(result.code, 0, `${argv.join(" ")}\n${result.stdout}${result.stderr}`);
	}

	const tree = readTree(root);
	for (const folder of ["Controllers", "Commands", "Hints", "ReplicationDomains"]) {
		assert.match(tree[`src/server/${folder}/init.luau`], /= requireDescendants\(script\)$/m, folder);
	}
	assert.match(tree[STARTUP], /^local Commands = require\(script\.Parent\.Commands\)\nlocal Controllers = require\(script\.Parent\.Controllers\)\nlocal Hints = require\(script\.Parent\.Hints\)\nlocal PlayerActors/m);
	assert.match(tree[STARTUP], /KRF\.Server\.Init\(\{\n\thints = Hints,\n\tcommands = Commands,\n\tcontrollers = Controllers,\n\ttags = Tags,\n\tresources = Resources,\n\tactions = Actions,\n\treplicationDomains = ReplicationDomains,\n\tactionRequestSchemas = ActionRequests,\n\}\)/);
	assert.ok(tree["src/server/Actions/Combat/Meditate.luau"].includes('id = "Combat.Meditate"'));
	assert.match(tree[`${REQUESTS}/Fireball.luau`], /^local Fireball: KRF\.ActionRequestSchemas = \{\n\tFireball = \{\},\n\}$/m);
	assert.match(tree[`${REQUESTS}/Guard.luau`], /\tGuard = \{\n\t\tstop = \{\},\n\t\tallowInputInterrupt = true,\n\t\trequiresClientRelease = true,\n\t\tonDisconnect = "Interrupt",\n\t\},\n\}/);
	assert.match(tree[`${POLICIES}/Guard.luau`], /^local Guard: KRF\.ActionInputPolicies = \{\n\tGuard = \{ activation = "WhileDown" \},\n\}$/m);
	assert.equal(tree[`${REQUESTS}/init.luau`], readTree(newProject(t))[`${REQUESTS}/init.luau`]);
	assert.match(tree["src/server/Commands/CastSpell.luau"], /authorize = function[^\n]*\n\t\treturn false, "NotImplemented"/);
	assert.match(tree["src/server/Hints/Ping.luau"], /authorize = function[^\n]*\n\t\treturn false, "NotImplemented"/);
	assert.doesNotMatch(tree["src/server/Hints/ImpactFx.luau"], /authorize|receive/);
	assert.match(tree["src/server/ReplicationDomains/ComboState.luau"], /audience = "Owner"/);

	const startupBefore = tree[STARTUP];
	const second = await generate(root, ["controller", "--name", "Threat", "--yes"]);
	assert.equal(second.code, 0, second.stderr);
	assert.equal(readTree(root)[STARTUP], startupBefore);
});

test("Full and Hybrid projects get identical generated source", async (t) => {
	const full = newProject(t, "full");
	const hybrid = newProject(t, "hybrid");
	for (const argv of EVERY_KIND) {
		await generate(full, [...argv, "--yes"]);
		await generate(hybrid, [...argv, "--yes"]);
	}
	assert.deepEqual(source(hybrid), source(full));
});

test("the same request produces the same bytes in every fresh project", async (t) => {
	const first = newProject(t);
	const second = newProject(t);
	for (const argv of EVERY_KIND) {
		await generate(first, [...argv, "--yes"]);
		await generate(second, [...argv, "--yes"]);
	}
	assert.deepEqual(readTree(second), readTree(first));
});

test("--requestable writes request and policy modules; a customized request loader stays byte-for-byte unchanged", async (t) => {
	const root = newProject(t);
	const before = readTree(root);
	const requested = await generate(root, ["action", "--name", "Fireball", "--requestable", "--yes"]);
	assert.equal(requested.code, 0, requested.stderr);
	assert.deepEqual(changedFiles(before, readTree(root)), ["src/server/Actions/Fireball.luau", `${REQUESTS}/Fireball.luau`]);
	assert.match(requested.stdout, /Loadout\.Equip\("AbilitySlot1", "Fireball"\) in src\/client\/Controls\/Loadout\.luau/);

	const loader = `${REQUESTS}/init.luau`;
	const customized = readTree(root)[loader].replace("mergeDescendants(script)", "table.freeze(mergeDescendants(script.Parent.MyRequests))");
	fs.writeFileSync(path.join(root, loader), customized);

	const result = await generate(root, ["action", "--name", "Guard", "--recipe", "held", "--requestable", "--yes", "--json"]);
	assert.equal(result.code, 5);
	assert.equal(result.json.status, "manual-wiring-required");
	assert.equal(fs.readFileSync(path.join(root, loader), "utf8"), customized);
	assert.deepEqual(
		result.json.changes.map((change) => [change.change, change.path]),
		[
			["create", "src/server/Actions/Guard.luau"],
			["create", `${POLICIES}/Guard.luau`],
		],
	);
	assert.deepEqual(result.json.manual, [
		{
			file: REQUESTS,
			instruction: "Add this entry to the ActionRequestSchemas your project passes to KRF.",
			lines: ["\tGuard = {", "\t\tstop = {},", "\t\tallowInputInterrupt = true,", "\t\trequiresClientRelease = true,", '\t\tonDisconnect = "Interrupt",', "\t},"],
		},
	]);
});

test("request parameters get schemas, and input policies get producers that return a matching payload", async (t) => {
	const root = newProject(t);
	const result = await generate(root, ["action", "--name", "Guard", "--recipe", "held", "--requestable", "--start-field", "Element:Enum(Fire|Ice)", "--stop-field", "Direction:Array(F32,3)", "--yes"]);
	assert.equal(result.code, 0, result.stderr);
	assert.match(result.stdout, /Return the parameters input sends from the producers in src\/client\/ActionInputPolicies\/Guard\.luau\./);

	const tree = readTree(root);
	assert.match(tree[`${REQUESTS}/Guard.luau`], /\tGuard = \{\n\t\tstart = KRF\.Schema\.Struct\(\{\n\t\t\tElement = KRF\.Schema\.Enum\(\{ "Fire", "Ice" \}\),\n\t\t\}\),\n\t\tstop = \{\n\t\t\tparameters = KRF\.Schema\.Struct\(\{\n\t\t\t\tDirection = KRF\.Schema\.Array\(KRF\.Schema\.F32, 3\),\n\t\t\t\}\),\n\t\t\},/);
	assert.equal(
		tree[`${POLICIES}/Guard.luau`].split("\n").slice(5).join("\n"),
		`local Guard: KRF.ActionInputPolicies = {
	Guard = {
		activation = "WhileDown",
		startParameters = function(_context: KRF.ActionInputContext): { [string]: any }
			return {
				Element = "Fire",
			}
		end,
		stopParameters = function(_context: KRF.ActionInputContext): { [string]: any }
			return {
				Direction = {},
			}
		end,
	},
}

return Guard
`,
	);

	const oneShot = await generate(root, ["action", "--name", "Bolt", "--requestable", "--start-field", "Target:Optional(U32)", "--yes"]);
	assert.equal(oneShot.code, 0, oneShot.stderr);
	assert.match(readTree(root)[`${POLICIES}/Bolt.luau`], /\tBolt = \{\n\t\tstartParameters = function\(_context: KRF\.ActionInputContext\): \{ \[string\]: any \}\n\t\t\treturn \{\}\n\t\tend,\n\t\},/);
});

test("an Action whose request another module already declares gets a warning instead of a second declaration", async (t) => {
	const root = newProject(t);
	const focusRequests = `${REQUESTS}/Focus.luau`;
	const focusSource = readTree(root)[focusRequests];
	fs.writeFileSync(path.join(root, focusRequests), focusSource.replace("\n}\n\nreturn", '\n\t["Combat.Dash"] = {},\n}\n\nreturn'));

	const declared = await generate(root, ["action", "--name", "Dash", "--id", "Combat.Dash", "--requestable", "--yes", "--json"]);
	assert.equal(declared.code, 0, declared.stderr);
	assert.deepEqual(declared.json.warnings, [`${focusRequests} already declares Combat.Dash; it was left unchanged.`]);
	assert.deepEqual(
		declared.json.changes.map((change) => change.path),
		["src/server/Actions/Combat/Dash.luau"],
	);
});

test("a customized Startup stays unchanged; the loader is still created and the exact lines are reported", async (t) => {
	const root = newProject(t);
	const customized = readTree(root)[STARTUP].replace("KRF.Server.Init({", "KRF.Server.Init(table.freeze({").replace("\n})\n", "\n}))\n");
	fs.writeFileSync(path.join(root, STARTUP), customized);

	const result = await generate(root, ["controller", "--name", "Cooldowns", "--yes", "--json"]);
	assert.equal(result.code, 5);
	assert.equal(fs.readFileSync(path.join(root, STARTUP), "utf8"), customized);
	assert.deepEqual(
		result.json.changes.map((change) => change.path),
		["src/server/Controllers/Cooldowns.luau", "src/server/Controllers/init.luau"],
	);
	assert.deepEqual(result.json.manual, [
		{
			file: STARTUP,
			instruction: "Require the Controllers loader with the other requires and pass it to KRF.Server.Init as controllers.",
			lines: ["local Controllers = require(script.Parent.Controllers)", "\tcontrollers = Controllers,"],
		},
	]);

	const human = await generate(root, ["command", "--name", "CastSpell", "--yes"]);
	assert.equal(human.code, 5);
	assert.match(human.stdout, /^Created src\/server\/Commands\/CastSpell\.luau\. Finish wiring it by hand:\n {2}created src\/server\/Commands\/init\.luau\n\nsrc\/server\/Startup\.server\.luau: Require the Commands loader[^\n]*\n {4}local Commands = require\(script\.Parent\.Commands\)\n {4}\tcommands = Commands,\n/);
});

test("rerunning a request reports already-exists and writes nothing, so no require or request entry is duplicated", async (t) => {
	const root = newProject(t);
	await generate(root, ["controller", "--name", "Cooldowns", "--yes"]);
	await generate(root, ["action", "--name", "Fireball", "--requestable", "--yes"]);
	const before = readTree(root);

	for (const argv of [
		["controller", "--name", "Cooldowns"],
		["action", "--name", "Fireball", "--requestable"],
	]) {
		const result = await generate(root, [...argv, "--yes", "--json"]);
		assert.equal(result.code, 3);
		assert.equal(result.json.status, "already-exists");
		assert.deepEqual(result.json.changes, []);
	}
	assert.deepEqual(readTree(root), before);
	assert.equal(before[STARTUP].match(/require\(script\.Parent\.Controllers\)/g).length, 1);
	assert.equal(Object.keys(before).filter((file) => file.startsWith(`${REQUESTS}/`) && /\tFireball = /.test(before[file])).length, 1);
});

test("refuses duplicate IDs and case-colliding paths before writing anything", async (t) => {
	const root = newProject(t);
	const before = readTree(root);

	const duplicate = await generate(root, ["action", "--name", "Fireball", "--id", "Focus", "--yes"]);
	assert.equal(duplicate.code, 1);
	assert.match(duplicate.stderr, /src\/server\/Actions\/Focus\.luau already defines the Action 'Focus'/);

	const collision = await generate(root, ["tag", "--output", "src/server/tags/Rooted.luau", "--yes"]);
	assert.equal(collision.code, 1);
	assert.match(collision.stderr, /NameConflict|already uses the name/);

	const wrongCatalog = await generate(root, ["tag", "--output", "src/server/Actions/Rooted.luau", "--yes"]);
	assert.equal(wrongCatalog.code, 2);
	assert.match(wrongCatalog.stderr, /inside src\/server\/Actions, which holds actions/);

	assert.deepEqual(readTree(root), before);
});

test("--output outside every loaded folder writes the file and reports created-not-loaded without a request entry", async (t) => {
	const root = newProject(t);
	const result = await generate(root, ["action", "--output", "src/server/Library/Fireball.luau", "--requestable", "--yes", "--json"]);
	assert.equal(result.code, 4);
	assert.equal(result.json.status, "created-not-loaded");
	assert.deepEqual(result.json.changes, [{ path: "src/server/Library/Fireball.luau", change: "create" }]);
	assert.deepEqual(result.json.manual, [
		{ file: `${REQUESTS}/Fireball.luau`, instruction: "Once Fireball loads, create this module returning its ActionRequestSchemas entry.", lines: ["\tFireball = {},"] },
	]);
	assert.equal(fs.existsSync(path.join(root, REQUESTS, "Fireball.luau")), false);

	const nested = await generate(root, ["action", "--output", "src/server/Actions/Combat/Slash.luau", "--yes"]);
	assert.equal(nested.code, 0, nested.stderr);
});

test("--dry-run plans every change and writes nothing", async (t) => {
	const root = newProject(t);
	const before = readTree(root);
	const result = await generate(root, ["controller", "--name", "Cooldowns", "--dry-run", "--json"]);
	assert.equal(result.code, 0);
	assert.equal(result.json.status, "dry-run");
	assert.equal(result.json.outcome, "created");
	assert.deepEqual(
		result.json.changes.map((change) => [change.change, change.path]),
		[
			["create", "src/server/Controllers/Cooldowns.luau"],
			["create", "src/server/Controllers/init.luau"],
			["edit", STARTUP],
		],
	);
	assert.deepEqual(readTree(root), before);

	const human = await generate(root, ["action", "--name", "Fireball", "--dry-run"]);
	assert.match(human.stdout, /^Dry run: would create the Action Fireball \(created\)\. Nothing was written\.\n {2}would create src\/server\/Actions\/Fireball\.luau\n/);
	assert.deepEqual(readTree(root), before);
});

test("--json prints exactly one result object for successes, partial results and errors", async (t) => {
	const root = newProject(t);
	const created = await generate(root, ["tag", "--name", "Stunned", "--yes", "--json"]);
	assert.deepEqual(Object.keys(created.json), ["status", "kind", "name", "id", "file", "changes", "manual", "next", "warnings"]);
	assert.equal(created.json.file, "src/server/Tags/Stunned.luau");

	const warned = await generate(root, ["action", "--name", "Fireball", "--blocked-tag", "Silenced", "--yes", "--json"]);
	assert.equal(warned.code, 0);
	assert.deepEqual(warned.json.warnings, ["Tag 'Silenced' is not defined in src/server/Tags; KRF rejects startup until it is."]);
	assert.match(warned.stderr, /^warning: Tag 'Silenced'/);

	for (const argv of [["tag", "--json"], ["tag", "--name", "bad", "--json"], ["tag", "--name", "Rooted", "--bogus", "--json"]]) {
		const failed = await generate(root, argv);
		assert.equal(failed.code, 2, argv.join(" "));
		assert.equal(failed.json.status, "error");
		assert.equal(typeof failed.json.error.code, "string");
		assert.notEqual(failed.stderr, "");
	}
});

async function wizardMatchesFlags(t, kind, answers, flags) {
	const wizardRoot = newProject(t);
	const scripted = scriptedPrompts(answers);
	const wizard = await generate(wizardRoot, [kind], { prompts: scripted.prompts });
	assert.equal(wizard.code, 0, wizard.stderr);
	for (const [message, answer] of Object.entries(answers)) {
		if (Array.isArray(answer)) assert.deepEqual(answer, [], `unused answers for: ${message}`);
	}

	const flagRoot = newProject(t);
	const flagged = await generate(flagRoot, [kind, ...flags]);
	assert.equal(flagged.code, 0, flagged.stderr);
	assert.deepEqual(readTree(wizardRoot), readTree(flagRoot));
	return scripted.asked;
}

test("the Action wizard asks one plain question at a time and writes what the equivalent flags write", async (t) => {
	const asked = await wizardMatchesFlags(
		t,
		"action",
		{
			Name: "Fireball",
			"How does it end?": "channel",
			"How many seconds does it last?": "2",
			"Should every Actor be able to use it? (no: you grant it with ActionController:SetGrants)": false,
			"Tags the Actor must have before it can start (space to select, enter to continue)": [[]],
			"Tags that stop it from starting (space to select, enter to continue)": [["Focused", NOT_LISTED]],
			"Which other Tags? (separated by commas)": "Stunned",
			"While it runs, should the Actor have a Tag, such as Casting? (removed when it ends)": true,
			"Which Tag?": "Focused",
			"Remove Focused after how many seconds? (blank: when it ends)": "2",
			"Add another Tag the Actor has while it runs?": false,
			"When it starts, should it give the Actor a Tag that stays after it ends, such as Burning?": false,
			"Must a Resource be at a certain level before it can start?": true,
			"Which Resource must be at a certain level?": "Energy",
			"Which checks on Energy? (space to select, enter to continue)": [["min", "maxPercent"]],
			"Energy must be at least": "10",
			"Energy must be at most what percent of its maximum? (0-100)": "90",
			"Add another Resource requirement?": false,
			"Does starting it cost a Resource?": true,
			"Which Resource does it cost?": "Energy",
			"How is the Energy cost measured?": "percent",
			"What percent of Energy's range does it cost?": "25",
			"Should a property scale the Energy cost? (for example a cost multiplier stat)": false,
			"Add another cost?": false,
			"Should it block other Actions on the same Actor while it runs? (locks: Actions that share a lock never run at the same time)": true,
			"Which locks does it hold? (separated by commas, blank for none)": "Hands",
			"If another Action needs Hands while this one runs, may some Actions cancel this one and take over?": true,
			"Which Actions may cancel it and take over its locks? (space to select, enter to continue)": [["Focus"]],
			"Which other lifecycle hooks should it have? (space to select, enter to continue)": [["onEnd", "canBeInterruptedBy"]],
			"Can players start it from the client, for example with a key?": true,
			"Does the client send any data when it starts it?": true,
			"Field name": "Target",
			"What kind of value is Target?": "U32",
			"Can Target be left out?": true,
			"Add another start field?": false,
			"Can the player stop it early?": false,
			"Can the player's input cancel it, for example when the key binding is removed?": false,
			"If the player who started it leaves the game:": "Interrupt",
		},
		[
			"--name",
			"Fireball",
			"--recipe",
			"channel",
			"--duration",
			"2",
			"--blocked-tag",
			"Focused",
			"--blocked-tag",
			"Stunned",
			"--active-tag",
			"Focused:2",
			"--requirement",
			"Energy:min=10,maxPercent=0.9",
			"--cost",
			"Energy:percent=0.25",
			"--lock",
			"Hands",
			"--interruptible-by",
			"Focus",
			"--hook",
			"onEnd",
			"--hook",
			"canBeInterruptedBy",
			"--requestable",
			"--start-field",
			"Target:Optional(U32)",
			"--on-disconnect",
			"Interrupt",
		],
	);
	assert.ok(asked.every((message) => !/TagId|Resource:|Name:Type|=/.test(message)), "no question asks for flag syntax");
});

test("the Tag, Resource and replication domain wizards build modifiers, numeric sources and schemas from questions", async (t) => {
	await wizardMatchesFlags(
		t,
		"tag",
		{
			Name: "Burning",
			"Who can see it?": "ServerOnly",
			"What happens when it is added to an Actor that already has it?": "Stack",
			"Most stacks it can have (blank: no limit)": "3",
			"How many seconds does it last by default? (blank: until removed)": "",
			"Should it run code repeatedly while active? (onTick)": true,
			"Every how many seconds?": "0.5",
			"Does it change a property, such as WalkSpeed, while active?": true,
			"Which property does it change?": [NOT_LISTED, "EnergyRegen"],
			"Which property?": "WalkSpeed",
			"How does it change WalkSpeed?": "adjust",
			"How does it adjust WalkSpeed? (space to select, enter to continue)": [["multiply", "min"]],
			"Multiply WalkSpeed by": "0.5",
			"Keep WalkSpeed at or above": "4",
			"Change another property?": [true, false],
			"How does it change EnergyRegen?": "set",
			"Set EnergyRegen to": "0",
		},
		["--name", "Burning", "--duplicate-behavior", "Stack", "--max-stacks", "3", "--tick-interval", "0.5", "--property", "WalkSpeed:multiply=0.5,min=4", "--property", "EnergyRegen:set=0"],
	);

	await wizardMatchesFlags(
		t,
		"resource",
		{
			Name: "Mana",
			"Where does its maximum come from?": "property",
			"Property name": "MaxMana",
			"MaxMana's default base value": "50",
			"Can it have a minimum other than 0?": false,
			"What value does it start at? (blank: its maximum)": "0",
			"Does it regenerate over time?": true,
			"Where does its regeneration per second come from?": "value",
			"What is its regeneration per second?": "2",
			"Who can see it?": "ClientVisible",
			"Should every Actor have it automatically?": true,
		},
		["--name", "Mana", "--max", "MaxMana=50", "--initial", "0", "--regen", "2", "--visibility", "ClientVisible"],
	);

	await wizardMatchesFlags(
		t,
		"domain",
		{
			Name: "ComboState",
			"Which players receive it?": "All",
			"Does it replicate any state?": true,
			"Field name": ["Count", "Damage"],
			"What kind of value is Count?": "Array",
			"What kind of value is each item in Count?": "Enum",
			"Names each item in Count can be, separated by commas": "Fire, Ice",
			"Most items Count can hold": "4",
			"Can Count be left out?": false,
			"Add another state field?": false,
			"Does it send events, such as a combo finisher?": true,
			"Event ID": "Finisher",
			"Does Finisher carry any data?": true,
			"What kind of value is Damage?": "U16",
			"Can Damage be left out?": false,
			"Add another Finisher field?": false,
			"Add another event?": false,
		},
		["--name", "ComboState", "--audience", "All", "--state-field", "Count:Array(Enum(Fire|Ice),4)", "--event", "Finisher(Damage:U16)"],
	);
});

test("the wizard skips what flags already answered and never asks with --yes", async (t) => {
	const root = newProject(t);
	const partial = scriptedPrompts({
		"Who sends it?": "ClientToServer",
		"Which sends matter?": "Latest",
		"Does it carry any data?": true,
		"Field name": "Sent",
		"What kind of value is Sent?": "F64",
		"Can Sent be left out?": false,
		"Add another payload field?": false,
		"Which players may send it?": "AnyReadyClient",
	});
	const result = await generate(root, ["hint", "--name", "Ping", "--target", "None"], { prompts: partial.prompts });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(partial.asked, [
		"Who sends it?",
		"Which sends matter?",
		"Does it carry any data?",
		"Field name",
		"What kind of value is Sent?",
		"Can Sent be left out?",
		"Add another payload field?",
		"Which players may send it?",
	]);
	assert.match(readTree(root)["src/server/Hints/Ping.luau"], /Sent = KRF\.Schema\.F64,[\s\S]*authorize = KRF\.HintAuthorization\.AnyReadyClient,/);

	const silent = scriptedPrompts({});
	const yes = await generate(root, ["domain", "--name", "ComboState", "--yes"], { prompts: silent.prompts });
	assert.equal(yes.code, 0, yes.stderr);
	assert.deepEqual(silent.asked, []);
});

test("cancelling the wizard or omitting the name without a terminal writes nothing", async (t) => {
	const root = newProject(t);
	const before = readTree(root);

	const cancelled = await generate(root, ["resource"], { prompts: scriptedPrompts({ Name: "Stamina", "Where does its maximum come from?": CANCEL }).prompts });
	assert.equal(cancelled.code, 130);
	assert.match(cancelled.stderr, /Cancelled\. No files were written/);

	const nameless = await generate(root, ["resource", "--max", "10"]);
	assert.equal(nameless.code, 2);
	assert.match(nameless.stderr, /A name is required when not running interactively\.\nPass it with --name, for example: npm run createResource -- --name Example/);

	assert.deepEqual(readTree(root), before);
});

test("runs from any directory inside the project and refuses an unsupported KRF version", async (t) => {
	const root = newProject(t);
	const nested = await generate(root, ["tag", "--name", "Stunned", "--yes"], { cwd: path.join(root, "src", "client") });
	assert.equal(nested.code, 0, nested.stderr);
	assert.equal(fs.existsSync(path.join(root, "src/server/Tags/Stunned.luau")), true);

	fs.writeFileSync(path.join(root, "wally.toml"), readTree(root)["wally.toml"].replace(/@=[\d.]+/, "@=9.0.0"));
	const before = readTree(root);
	const unsupported = await generate(root, ["tag", "--name", "Rooted", "--yes"]);
	assert.equal(unsupported.code, 1);
	assert.match(unsupported.stderr, /this project uses 9\.0\.0/);
	assert.deepEqual(readTree(root), before);
});

test("--help documents each generator's flags", async (t) => {
	const root = newProject(t);
	const help = await generate(root, ["action", "--help"]);
	assert.equal(help.code, 0);
	for (const flag of ["--name", "--id", "--output", "--recipe", "--duration", "--requestable", "--auto-grant", "--active-tag", "--blocked-tag", "--cost", "--dry-run", "--json", "--yes"]) {
		assert.match(help.stdout, new RegExp(flag), flag);
	}
	assert.match(help.stdout, /npm run createAction -- --name Fireball/);

	const unknown = await generate(root, ["spell", "--name", "Fireball"]);
	assert.equal(unknown.code, 2);
});
