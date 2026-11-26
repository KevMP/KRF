import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { KRF_RUNTIME, runGenerator, writeNewDirectory } from "@kevmp/krf-tools";

import { buildProjectFiles } from "../src/create.js";

const CANCEL = Symbol("cancel");

const STARTUP = "src/server/Startup.server.luau";
const CLIENT_STARTUP = "src/client/Startup.client.luau";
const REQUESTS = "src/shared/ActionRequests";
const POLICIES = "src/client/ActionInputPolicies";

const EVERY_KIND = [
	["tag", "--name", "Stunned", "--duration", "2"],
	["resource", "--name", "Stamina", "--max", "50"],
	["action", "--name", "Fireball", "--requestable", "--auto-grant", "--blocked-tag", "Stunned", "--cost", "Stamina=10"],
	["action", "--name", "Guard", "--recipe", "held", "--requestable"],
	["action", "--name", "Shield", "--recipe", "toggle", "--requestable"],
	["action", "--id", "Combat.Meditate", "--recipe", "channel", "--duration", "0.5"],
	["controller", "--name", "Cooldowns", "--depends-on", "ResourceController"],
	["command", "--name", "CastSpell"],
	["hint", "--name", "ImpactFx"],
	["hint", "--name", "Ping", "--direction", "ClientToServer"],
	["domain", "--name", "ComboState"],
	["presentation", "--name", "FireballFlash", "--source-id", "Fireball"],
];

function newProject(t, mode = "full") {
	const parent = fs.mkdtempSync(path.join(os.tmpdir(), "krf-generate-"));
	t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
	const root = path.join(parent, "my-game");
	writeNewDirectory(root, buildProjectFiles({ target: root, name: "my-game", options: { mode, ci: false, agents: false }, git: false }));
	return root;
}

function installLocalPresentationRuntime(root) {
	const folder = path.join(root, "Packages", "_Index", `kevmp_krf@${KRF_RUNTIME.version}`, "krf", "src", "client", "Presentation");
	fs.mkdirSync(folder, { recursive: true });
	fs.copyFileSync(new URL("../../../src/client/Presentation/PresentationEvents.luau", import.meta.url), path.join(folder, "PresentationEvents.luau"));
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
	installLocalPresentationRuntime(root);
	for (const argv of EVERY_KIND) {
		const result = await generate(root, [...argv, "--yes"]);
		assert.equal(result.code, 0, `${argv.join(" ")}\n${result.stdout}${result.stderr}`);
	}

	const tree = readTree(root);
	for (const folder of ["Controllers", "Commands", "Hints", "ReplicationDomains"]) {
		assert.match(tree[`src/server/${folder}/init.luau`], /= requireDescendants\(script\)$/m, folder);
	}
	assert.match(tree[STARTUP], /^local Commands = require\(script\.Parent\.Commands\)\nlocal Controllers = require\(script\.Parent\.Controllers\)\nlocal Hints = require\(script\.Parent\.Hints\)\nlocal PlayerActors/m);
	assert.match(tree[STARTUP], /KRF\.Server\.Init\(\{\n\thints = Hints,\n\tcommands = Commands,\n\tcontrollers = Controllers,\n\tproperties = Properties,\n\ttags = Tags,\n\tresources = Resources,\n\tactions = Actions,\n\treplicationDomains = ReplicationDomains,\n\tactionRequestSchemas = ActionRequests,\n\}\)/);
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

test("createPresentation installs the client catalog once and loads later definitions from the same folder", async (t) => {
	const root = newProject(t);
	installLocalPresentationRuntime(root);
	const before = readTree(root);
	const argv = ["presentation", "--name", "SwingHighlight", "--id", "Combat.SwingHighlight", "--source-id", "Sword.Swing", "--yes", "--json"];
	const preview = await generate(root, [...argv, "--dry-run"]);
	assert.equal(preview.code, 0, preview.stderr);
	assert.deepEqual(readTree(root), before);

	const result = await generate(root, argv);
	assert.equal(result.code, 0, result.stderr);
	assert.equal(result.json.status, "created");

	const after = readTree(root);
	assert.deepEqual(changedFiles(before, after), ["src/client/Presentations/Combat/SwingHighlight.luau", "src/client/Presentations/init.luau", CLIENT_STARTUP]);
	assert.match(after["src/client/Presentations/init.luau"], /: \{ KRF\.PresentationDefinition \} = requireDescendants\(script\)/);
	assert.match(after["src/client/Presentations/Combat/SwingHighlight.luau"], /local SwingHighlight: KRF\.PresentationDefinition = /);
	assert.match(after["src/client/Presentations/Combat/SwingHighlight.luau"], /entry = \{ event = KRF\.PresentationEvents\.Action\.Started, id = "Sword\.Swing" \}/);
	assert.match(after["src/client/Presentations/Combat/SwingHighlight.luau"], /create = function\(context: KRF\.PresentationContext\): \(\)[\s\S]*context:Finish\(\)/);
	assert.match(after[CLIENT_STARTUP], /local Presentations = require\(script\.Parent\.Presentations\)/);
	assert.match(after[CLIENT_STARTUP], /KRF\.Client\.Init\(\{[\s\S]*\tpresentations = Presentations,/);

	const next = await generate(root, ["presentation", "--name", "WorldBurst", "--event", "Hint.Received", "--source-id", "World.Impact", "--yes"]);
	assert.equal(next.code, 0, next.stderr);
	const final = readTree(root);
	assert.deepEqual(changedFiles(after, final), ["src/client/Presentations/WorldBurst.luau"]);
	assert.match(final["src/client/Presentations/WorldBurst.luau"], /KRF\.PresentationEvents\.Hint\.Received/);
});

test("createPresentation leaves a custom client startup alone and reports where to wire it", async (t) => {
	const root = newProject(t);
	installLocalPresentationRuntime(root);
	const startup = readTree(root)[CLIENT_STARTUP].replace("KRF.Client.Init({", "KRF.Client.Init(table.freeze({").replace("\n})", "\n}))");
	fs.writeFileSync(path.join(root, CLIENT_STARTUP), startup);

	const result = await generate(root, ["presentation", "--name", "StatusGlow", "--event", "Tag.Added", "--source-id", "Blocking", "--yes", "--json"]);
	assert.equal(result.code, 5, result.stderr);
	assert.equal(result.json.status, "manual-wiring-required");
	assert.equal(readTree(root)[CLIENT_STARTUP], startup);
	assert.match(JSON.stringify(result.json.manual), /KRF\.Client\.Init/);
});

test("createPresentation rejects an invalid event or missing selector before writing", async (t) => {
	const root = newProject(t);
	const before = readTree(root);
	for (const options of [["--event", "Action.Unknown", "--source-id", "Swing"], []]) {
		const result = await generate(root, ["presentation", "--name", "Highlight", ...options, "--yes", "--json"]);
		assert.notEqual(result.code, 0);
		assert.equal(result.json.error.code, "InvalidOption");
		assert.deepEqual(readTree(root), before);
	}
});


test("createPresentation refuses a published runtime without Presentation before editing startup", async (t) => {
	const root = newProject(t);
	const manifest = path.join(root, "wally.toml");
	fs.writeFileSync(manifest, fs.readFileSync(manifest, "utf8").replace(`kevmp/krf@=${KRF_RUNTIME.version}`, "kevmp/krf@=0.2.1"));
	const before = readTree(root);
	const result = await generate(root, ["presentation", "--name", "SwingHighlight", "--source-id", "Sword.Swing", "--yes", "--json"]);
	assert.notEqual(result.code, 0);
	assert.equal(result.json.error.code, "PresentationRuntimeUnsupported");
	assert.deepEqual(readTree(root), before);
});

test("Full and Hybrid projects get identical generated source", async (t) => {
	const full = newProject(t, "full");
	const hybrid = newProject(t, "hybrid");
	installLocalPresentationRuntime(full);
	installLocalPresentationRuntime(hybrid);
	for (const argv of EVERY_KIND) {
		await generate(full, [...argv, "--yes"]);
		await generate(hybrid, [...argv, "--yes"]);
	}
	assert.deepEqual(source(hybrid), source(full));
});

test("the same request produces the same bytes in every fresh project", async (t) => {
	const first = newProject(t);
	const second = newProject(t);
	installLocalPresentationRuntime(first);
	installLocalPresentationRuntime(second);
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
		startParameters = function(_context: KRF.ActionInputContext): {
			Element: "Fire" | "Ice",
		}
			return {
				Element = "Fire",
			}
		end,
		stopParameters = function(_context: KRF.ActionInputContext): {
			Direction: { number },
		}
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
	assert.match(readTree(root)[`${POLICIES}/Bolt.luau`], /\tBolt = \{\n\t\tstartParameters = function\(_context: KRF\.ActionInputContext\): \{\n\t\t\tTarget: number\?,\n\t\t\}\n\t\t\treturn \{\}\n\t\tend,\n\t\},/);
});

test("a toggle Action stops on the next press, without requiring a release", async (t) => {
	const root = newProject(t);
	const plain = await generate(root, ["action", "--name", "Shield", "--recipe", "toggle", "--requestable", "--yes"]);
	assert.equal(plain.code, 0, plain.stderr);

	let tree = readTree(root);
	assert.match(tree["src/server/Actions/Shield.luau"], /\t\tonStopRequested = function\(context: KRF\.ActionExecutionContext\): \(\)\n\t\t\tcontext:End\(\)\n\t\tend,/);
	assert.doesNotMatch(tree["src/server/Actions/Shield.luau"], /onStart/);
	assert.match(tree[`${REQUESTS}/Shield.luau`], /\tShield = \{\n\t\tstop = \{\},\n\t\},/);
	assert.match(tree[`${POLICIES}/Shield.luau`], /\tShield = \{ activation = "Toggle" \},/);

	const withParameters = await generate(root, ["action", "--name", "Ward", "--recipe", "toggle", "--requestable", "--stop-field", "Strength:U8", "--on-disconnect", "Interrupt", "--yes"]);
	assert.equal(withParameters.code, 0, withParameters.stderr);
	assert.match(withParameters.stdout, /Return the parameters input sends from the producers in src\/client\/ActionInputPolicies\/Ward\.luau\./);

	tree = readTree(root);
	assert.match(tree[`${REQUESTS}/Ward.luau`], /\t\t\},\n\t\tallowInputInterrupt = true,\n\t\tonDisconnect = "Interrupt",\n\t\},/);
	assert.doesNotMatch(tree[`${REQUESTS}/Ward.luau`], /requiresClientRelease/);
	assert.match(tree[`${POLICIES}/Ward.luau`], /\t\tactivation = "Toggle",\n\t\tstopParameters = function/);
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
		assert.ok(scripted.asked.includes(message), `never asked: ${message}`);
	}

	const flagRoot = newProject(t);
	const flagged = await generate(flagRoot, [kind, ...flags]);
	assert.equal(flagged.code, 0, flagged.stderr);
	assert.deepEqual(readTree(wizardRoot), readTree(flagRoot));
	return { asked: scripted.asked, root: wizardRoot, stdout: wizard.stdout };
}

test("the Action wizard names each field, lets lists be typed, and writes what the equivalent flags write", async (t) => {
	const { asked, root, stdout } = await wizardMatchesFlags(
		t,
		"action",
		{
			"name (module and file name, such as Fireball)": "Fireball",
			"id (blank: Fireball; a namespace such as Combat.Fireball is allowed)": "Combat.Fireball",
			"recipe (which lifecycle hook ends the Action)": "channel",
			"duration (seconds the Action runs)": "2",
			"autoGrant (every Actor can use the Action without a grant)": false,
			"requiredTags (Tags the Actor must have for the Action to start; comma separated, blank for none; this project has Focused)": "",
			"blockedTags (Tags that stop the Action from starting; comma separated, blank for none; this project has Focused)": "Focused, Stunned",
			"activeTags (Tags applied while the Action runs, removed when the Action ends; comma separated, blank for none; this project has Focused)": "Focused",
			"activeTags.Focused.duration (seconds; blank: until the Action ends)": "2",
			"appliedTags (Tags applied when the Action starts; comma separated, blank for none; this project has Focused)": "Burning",
			"appliedTags.Burning.duration (seconds; blank: the Tag's default duration)": "",
			"resourceRequirements (Resources that must be at a certain level for the Action to start; comma separated, blank for none; this project has Energy)": "Energy",
			"resourceRequirements.Energy.min (lowest amount allowed; blank to skip)": "10",
			"resourceRequirements.Energy.max (highest amount allowed; blank to skip)": "",
			"resourceRequirements.Energy.minPercent (lowest percent of the Resource's maximum, 0-100; blank to skip)": "",
			"resourceRequirements.Energy.maxPercent (highest percent of the Resource's maximum, 0-100; blank to skip)": "90",
			"costs (Resources spent when the Action starts; comma separated, blank for none; this project has Energy)": "Energy",
			"costs.Energy (an amount such as 10, or a percent of the Resource's range such as 25%)": "25%",
			"costs.Energy.multiplierProperty (a Property whose value multiplies the cost; blank for none; this project has EnergyRegen, JumpPower, WalkSpeed)": "",
			"locks (lock names held while the Action runs; Actions that share a lock never run at the same time; comma separated, blank for none)": "Hands",
			"interruptibleBy (Actions allowed to end this Action and take over its locks; comma separated, blank for none; this project has Focus)": "Focus",
			"hooks (extra lifecycle hook stubs; space to select, enter to confirm)": [["onEnd", "canBeInterruptedBy"]],
			"requestable (players can request the Action from the client)": true,
			"visibility (who can see the Action)": "ServerOnly",
			"start field name (parameters the client sends when requesting the Action; blank to finish)": ["Target", ""],
			"start.Target type": "U32",
			"start.Target optional (the field can be left out)": true,
			"stop (the client can request a Stop; a Stop does not end the Action by itself, onStopRequested decides what happens)": true,
			"stop.parameters field name (parameters the client sends with a Stop; blank to finish)": [""],
			"allowInputInterrupt (client input can interrupt the Action)": false,
			"onDisconnect (what happens to the Action when the requesting player leaves)": "Interrupt",
		},
		[
			"--name",
			"Fireball",
			"--id",
			"Combat.Fireball",
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
			"--applied-tag",
			"Burning",
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
			"--visibility",
			"ServerOnly",
			"--start-field",
			"Target:Optional(U32)",
			"--client-stop",
			"--on-disconnect",
			"Interrupt",
		],
	);

	assert.ok(asked.every((message) => /^[A-Za-z.]+( [a-z ]+)? \(/.test(message) || / type$/.test(message)), "every question starts with the field it sets");
	const action = readTree(root)["src/server/Actions/Combat/Fireball.luau"];
	assert.match(action, /visibility = "ServerOnly",/);
	assert.match(action, /onStopRequested = function\(_context: KRF\.ActionExecutionContext, _request: KRF\.ActionStopRequest\): \(\) end,/);
	assert.match(stdout, /A Stop request does not end Combat\.Fireball by itself\. Decide what Stop does in onStopRequested in src\/server\/Actions\/Combat\/Fireball\.luau; call context:End\(\) there to end it\./);
});

test("the Tag, Resource and replication domain wizards ask for each field and write what the equivalent flags write", async (t) => {
	await wizardMatchesFlags(
		t,
		"tag",
		{
			"name (module and file name, such as Fireball)": "Burning",
			"id (blank: Burning; a namespace such as Combat.Burning is allowed)": "",
			"visibility (who can see the Tag)": "ServerOnly",
			"duplicateBehavior (what adding the Tag again does)": "Stack",
			"maxStacks (most stacks of the Tag allowed; blank for no limit)": "3",
			"defaultDuration (seconds the Tag lasts; blank: until removed)": "",
			"tickInterval (seconds between onTick calls; blank for no onTick)": "0.5",
			"properties (properties the Tag modifies while active; comma separated, blank for none; this project has EnergyRegen, JumpPower, WalkSpeed)": "WalkSpeed, EnergyRegen",
			"properties.WalkSpeed.set (replace the property with this value; blank to adjust the property instead)": "",
			"properties.WalkSpeed.add (amount added; blank to skip)": "",
			"properties.WalkSpeed.multiply (multiplier; blank to skip)": "0.5",
			"properties.WalkSpeed.min (lowest value allowed; blank to skip)": "4",
			"properties.WalkSpeed.max (highest value allowed; blank to skip)": "",
			"properties.EnergyRegen.set (replace the property with this value; blank to adjust the property instead)": "0",
		},
		["--name", "Burning", "--duplicate-behavior", "Stack", "--max-stacks", "3", "--tick-interval", "0.5", "--property", "WalkSpeed:multiply=0.5,min=4", "--property", "EnergyRegen:set=0"],
	);

	await wizardMatchesFlags(
		t,
		"resource",
		{
			"name (module and file name, such as Fireball)": "Mana",
			"id (blank: Mana; a namespace such as Combat.Mana is allowed)": "",
			"max (the Resource's maximum)": "property",
			"max.propertyName (a registered Property ID; this project has EnergyRegen, JumpPower, WalkSpeed)": "MaxMana",
			"min (the Resource's minimum; none means 0)": "none",
			"initialValue (the Resource's starting value; blank: the maximum)": "0",
			"regen.rate (how much the Resource regenerates per second)": "value",
			"regen.rate.value": "2",
			"visibility (who can see the Resource)": "ClientVisible",
			"autoAssign (every Actor gets the Resource automatically)": true,
		},
		["--name", "Mana", "--max", "MaxMana", "--initial", "0", "--regen", "2", "--visibility", "ClientVisible"],
	);

	await wizardMatchesFlags(
		t,
		"domain",
		{
			"name (module and file name, such as Fireball)": "ComboState",
			"id (blank: ComboState; a namespace such as Combat.ComboState is allowed)": "",
			"audience (which players receive the domain)": "All",
			"state field name (replicated state; blank to finish)": ["Count", "Bonus", ""],
			"state.Count type": "Array",
			"state.Count maxLength (most items the list holds)": "4",
			"state.Count[] type (each item in state.Count)": "Array",
			"state.Count[] maxLength (most items the list holds)": "2",
			"state.Count[][] type (each item in state.Count[])": "Enum",
			"state.Count[][] values (allowed names, comma separated)": "Fire, Ice",
			"state.Count optional (the field can be left out)": false,
			"state.Bonus type": "Map",
			"state.Bonus maxEntries (most entries the lookup table holds)": "2",
			"state.Bonus[key] type (each key in state.Bonus)": "String",
			"state.Bonus[key] maxBytes (longest text allowed, in bytes)": "8",
			"state.Bonus[value] type (each value in state.Bonus)": "Boolean",
			"state.Bonus optional (the field can be left out)": false,
			"events ID (a replicated event such as Finisher; blank to finish)": ["Finisher", ""],
			"events.Finisher.payload field name (data the event carries; blank to finish)": ["Damage", ""],
			"events.Finisher.payload.Damage type": "U16",
			"events.Finisher.payload.Damage optional (the field can be left out)": false,
		},
		["--name", "ComboState", "--audience", "All", "--state-field", "Count:Array(Array(Enum(Fire|Ice),2),4)", "--state-field", "Bonus:Map(String(8),Boolean,2)", "--event", "Finisher(Damage:U16)"],
	);
});

test("createProperty writes a registered Property, and references to unregistered Properties warn", async (t) => {
	const { root, stdout } = await wizardMatchesFlags(
		t,
		"property",
		{
			"name (module and file name, such as Fireball)": "MaxMana",
			"id (blank: MaxMana; a namespace such as Combat.MaxMana is allowed)": "",
			"defaultBaseValue (the Property's value on an Actor before Tag modifiers)": "100",
			"autoAssign (every Actor gets the Property automatically)": false,
		},
		["--name", "MaxMana", "--default", "100"],
	);
	assert.equal(
		readTree(root)["src/server/Properties/MaxMana.luau"],
		`--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local MaxMana: KRF.PropertyDefinition = {
	id = "MaxMana",
	defaultBaseValue = 100,
}

return MaxMana
`,
	);
	assert.match(stdout, /MaxMana is not auto-assigned\. Give it to an Actor with ActorRuntime\.RegisterActor\(model, \{ properties = \{ MaxMana = value \} \}\)/);

	const assigned = await generate(root, ["property", "--name", "Defense", "--default", "5", "--auto-assign", "--yes"]);
	assert.equal(assigned.code, 0, assigned.stderr);
	assert.match(readTree(root)["src/server/Properties/Defense.luau"], /\tdefaultBaseValue = 5,\n\tautoAssign = true,\n\}/);
	assert.doesNotMatch(assigned.stdout, /not auto-assigned/);

	const registered = await generate(root, ["resource", "--name", "Mana", "--max", "MaxMana", "--regen", "WalkSpeed", "--yes", "--json"]);
	assert.deepEqual(registered.json.warnings, []);

	const unregistered = [
		["tag", "--name", "Armored", "--property", "Armor:add=5", "--yes", "--json"],
		["resource", "--name", "Stamina", "--max", "MaxStamina", "--yes", "--json"],
		["action", "--name", "Blink", "--cost", "Energy:amount=5,multiplierProperty=BlinkCost", "--yes", "--json"],
	];
	for (const [argv, id] of unregistered.map((argv, index) => [argv, ["Armor", "MaxStamina", "BlinkCost"][index]])) {
		const result = await generate(root, argv);
		assert.equal(result.code, 0, result.stderr);
		assert.deepEqual(result.json.warnings, [`Property '${id}' is not defined in src/server/Properties; KRF rejects startup until it is.`]);
	}
});

test("the wizard rejects an out-of-range percent at the question itself", async (t) => {
	const root = newProject(t);
	const { prompts } = scriptedPrompts({
		"resourceRequirements (Resources that must be at a certain level for the Action to start; comma separated, blank for none; this project has Energy)": "Energy",
		"resourceRequirements.Energy.min (lowest amount allowed; blank to skip)": "",
		"resourceRequirements.Energy.max (highest amount allowed; blank to skip)": "",
		"resourceRequirements.Energy.minPercent (lowest percent of the Resource's maximum, 0-100; blank to skip)": "",
		"resourceRequirements.Energy.maxPercent (highest percent of the Resource's maximum, 0-100; blank to skip)": "150",
	});
	const before = readTree(root);
	const result = await generate(
		root,
		["action", "--name", "Fireball", "--id", "Fireball", "--recipe", "instant", "--auto-grant", "--required-tag", "Focused", "--blocked-tag", "Focused", "--active-tag", "Focused", "--applied-tag", "Focused"],
		{ prompts },
	);
	assert.equal(result.code, 1);
	assert.match(result.stderr, /Validation failed: Enter a number of at most 100\./);
	assert.deepEqual(readTree(root), before);
});

test("the wizard skips what flags already answered and never asks with --yes", async (t) => {
	const root = newProject(t);
	const partial = scriptedPrompts({
		"direction (who sends the Hint)": "ClientToServer",
		"mode (which sends of the Hint are delivered)": "Latest",
		"payload field name (data the Hint carries; blank to finish)": ["Sent", ""],
		"payload.Sent type": "F64",
		"payload.Sent optional (the field can be left out)": false,
		"authorize (which players may send the Hint)": "AnyReadyClient",
	});
	const result = await generate(root, ["hint", "--name", "Ping", "--id", "Net.Ping", "--target", "None"], { prompts: partial.prompts });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(partial.asked, [
		"direction (who sends the Hint)",
		"mode (which sends of the Hint are delivered)",
		"payload field name (data the Hint carries; blank to finish)",
		"payload.Sent type",
		"payload.Sent optional (the field can be left out)",
		"payload field name (data the Hint carries; blank to finish)",
		"authorize (which players may send the Hint)",
	]);
	assert.match(readTree(root)["src/server/Hints/Net/Ping.luau"], /Sent = KRF\.Schema\.F64,[\s\S]*authorize = KRF\.HintAuthorization\.AnyReadyClient,/);

	const silent = scriptedPrompts({});
	const yes = await generate(root, ["domain", "--name", "ComboState", "--yes"], { prompts: silent.prompts });
	assert.equal(yes.code, 0, yes.stderr);
	assert.deepEqual(silent.asked, []);
});

test("manual wiring for customized projects always includes code to add and where it goes", async (t) => {
	const root = newProject(t);
	const loader = "src/server/Actions/init.luau";
	fs.writeFileSync(path.join(root, loader), readTree(root)[loader].replace("requireDescendants(script)", "table.clone(require(script.List))"));
	const customLoader = await generate(root, ["action", "--id", "Combat.Fireball", "--yes", "--json"]);
	assert.equal(customLoader.code, 5);
	assert.deepEqual(customLoader.json.manual, [
		{
			file: loader,
			instruction: "This loader is customized, so the generator did not edit it. Add the new module to the list it returns; actions is the starter's name for that list, so use your own name if it differs.",
			lines: ["table.insert(actions, require(script.Combat.Fireball))"],
		},
	]);

	const startup = readTree(root)[STARTUP].replace("\ttags = Tags,", "\ttags = { Focused },");
	fs.writeFileSync(path.join(root, STARTUP), startup);
	const customField = await generate(root, ["tag", "--name", "Stunned", "--yes", "--json"]);
	assert.equal(customField.code, 5);
	assert.deepEqual(customField.json.manual, [
		{
			file: STARTUP,
			instruction:
				"tags in KRF.Server.Init is customized, so the generator cannot tell where that list is built. Require the module with the other requires, then add Stunned to the list you pass as tags.",
			lines: ["local Stunned = require(script.Parent.Tags.Stunned)"],
		},
	]);
	assert.equal(readTree(root)[STARTUP], startup);

	for (const result of [customLoader, customField]) {
		for (const step of result.json.manual) assert.notDeepEqual(step.lines, [], step.instruction);
	}
});

test("cancelling the wizard or omitting the name without a terminal writes nothing", async (t) => {
	const root = newProject(t);
	const before = readTree(root);

	const cancelled = await generate(root, ["resource"], { prompts: scriptedPrompts({ "name (module and file name, such as Fireball)": "Stamina", "id (blank: Stamina; a namespace such as Combat.Stamina is allowed)": "", "max (the Resource's maximum)": CANCEL }).prompts });
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
