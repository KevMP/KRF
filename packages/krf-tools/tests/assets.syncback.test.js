import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { runAssets } from "../src/assets/cli.js";
import { ExitCode } from "../src/errors.js";

const CODE = {
	ReplicatedStorage: { $className: "ReplicatedStorage", Packages: { $path: "Packages" }, Shared: { $path: "src/shared" } },
	ServerScriptService: { $className: "ServerScriptService", Game: { $path: "src/server" } },
};
const RULES = { ignoreTrees: ["ReplicatedStorage/Packages", "ReplicatedStorage/Shared", "ServerScriptService/Game", "Workspace/Terrain"] };
const FULL = { name: "my-game", tree: { $className: "DataModel", ...CODE, Workspace: { $className: "Workspace", $ignoreUnknownInstances: true, $path: "world/Workspace" } }, syncbackRules: RULES };
const BASEPLATE = '{\n  "className": "Part"\n}';
const GENERATED = "4b14589832b6fd28caf1b59c00000000";
const ARENA = (id) => `{\n  "className": "Model",\n  "children": [\n    {\n      "name": "Floor",\n      "className": "Part",\n      "properties": {\n        "Size": [\n          4.0\n        ],\n        "Anchored": true\n      },\n      "attributes": {\n        "Rojo_Id": "${id}"\n      }\n    }\n  ],\n  "attributes": {\n    "Rojo_Target_PrimaryPart": "${id}"\n  }\n}`;

function project(t, { tree = FULL, start, files = {}, git = false } = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-syncback-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const all = {
		"package.json": JSON.stringify({ name: "my-game" }),
		"wally.toml": '[dependencies]\nKRF = "kevmp/krf@=0.2.0"\n',
		"default.project.json": typeof tree === "string" ? tree : JSON.stringify(tree),
		...(start === undefined ? {} : { "start-place.project.json": JSON.stringify(start) }),
		"world/Workspace/Baseplate.model.json": BASEPLATE,
		"my-game.rbxl": "place",
		"src/server/Startup.server.luau": "print('hi')\n",
		...files,
	};
	for (const [file, contents] of Object.entries(all)) {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), contents);
	}
	if (git) fs.mkdirSync(path.join(root, ".git"));
	return root;
}

function capture() {
	const io = { out: "", err: "" };
	return Object.assign(io, { stdout: (text) => (io.out += text), stderr: (text) => (io.err += text) });
}

function fakeSystem(root, { version = "Rojo 7.7.1", plan = [], write = () => {}, fail, gitStatus = "", noGit = false } = {}) {
	const calls = [];
	const system = {
		platform: "linux",
		env: {},
		spawnSync(command, args, options) {
			calls.push({ command, args, env: options.env });
			if (command === "git") {
				if (noGit) return { error: Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" }) };
				return { status: 0, stdout: args[0] === "rev-parse" ? `${root}\n` : gitStatus, stderr: "" };
			}
			if (args[0] === "--version") return { status: 0, stdout: `${version}\n`, stderr: "" };
			const dryRun = args.includes("--dry-run");
			if (fail !== undefined && (fail.dryRun ?? true) === dryRun) {
				if (!dryRun) write(root);
				return { status: 1, stdout: "", stderr: `Beginning syncback...\n\x1b[31m[ERROR rojo] ${fail.message}\x1b[0m\n` };
			}
			if (dryRun) return { status: 0, stdout: plan.map((line) => `${line}\n`).join(""), stderr: "Beginning syncback...\n" };
			write(root);
			return { status: 0, stdout: "", stderr: "Beginning syncback...\nFinished syncback.\n" };
		},
	};
	return { system, calls, syncbacks: () => calls.filter((call) => call.args[0] === "syncback") };
}

async function syncback(root, fake, argv = []) {
	const io = capture();
	const code = await runAssets(["assets", "syncback", ...argv], { cwd: root, ...io }, fake.system);
	return { code, ...io };
}

const read = (root, file) => fs.readFileSync(path.join(root, ...file.split("/")), "utf8");
const write = (file, contents) => (root) => {
	fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
	fs.writeFileSync(path.join(root, file), contents);
};

test("the input must be an existing .rbxl or .rbxlx place, defaulting to the project's place", async (t) => {
	const root = project(t);
	for (const [argv, code, message] of [
		[["--input", "notes.txt"], ExitCode.usage, /--input notes\.txt is not a place file/],
		[["--input", "Missing.rbxlx"], ExitCode.failure, /Missing\.rbxlx does not exist/],
		[["--input", "world"], ExitCode.usage, /not a place file/],
		[["--bogus"], ExitCode.usage, /unknown option/],
	]) {
		const fake = fakeSystem(root);
		const result = await syncback(root, fake, argv);
		assert.equal(result.code, code, argv.join(" "));
		assert.match(result.err, message);
		assert.deepEqual(fake.syncbacks(), []);
	}

	fs.rmSync(path.join(root, "my-game.rbxl"));
	const missing = await syncback(root, fakeSystem(root));
	assert.equal(missing.code, ExitCode.failure);
	assert.match(missing.err, /my-game\.rbxl does not exist\.\nSave the place in Roblox Studio first/);
});

test("Rojo older than 7.7.1 is refused before anything runs", async (t) => {
	const root = project(t);
	const fake = fakeSystem(root, { version: "Rojo 7.6.1" });
	const result = await syncback(root, fake);
	assert.equal(result.code, ExitCode.failure);
	assert.match(result.err, /needs Rojo 7\.7\.1 or newer, but this project runs Rojo 7\.6\.1[\s\S]*rojo-rbx\/rojo@7\.7\.1/);
	assert.deepEqual(fake.syncbacks(), []);
});

test("malformed or unsafe project mappings fail with instructions and never run syncback", async (t) => {
	const unprotected = structuredClone(FULL);
	unprotected.syncbackRules.ignoreTrees = ["ReplicatedStorage/Packages", "ReplicatedStorage/Shared"];
	const outside = structuredClone(FULL);
	outside.tree.Workspace.$path = "../shared-world";
	const missing = structuredClone(FULL);
	missing.tree.Workspace.$path = "world/Missing";
	const badRules = structuredClone(FULL);
	badRules.syncbackRules.ignoreTrees = "ServerScriptService";
	const nested = structuredClone(FULL);
	nested.tree.Workspace.$path = "world/Workspace/../world.project.json";

	for (const [tree, message, files] of [
		["{ nope", /default\.project\.json is not a valid Rojo project/],
		[{ name: "x" }, /is not a valid Rojo project: it has no tree object/],
		[badRules, /ignoreTrees in default\.project\.json must be a list/],
		[unprotected, /ServerScriptService\/Game maps src\/server, which holds code or installed packages[\s\S]*Add "ServerScriptService\/Game" to syncbackRules\.ignoreTrees/],
		[outside, /maps \.\.\/shared-world, which is outside the project/],
		[missing, /maps world\/Missing, which does not exist[\s\S]*\.gitkeep/],
		[nested, /maps the nested project/, { "world/world.project.json": "{}" }],
	]) {
		const root = project(t, { tree, files });
		const fake = fakeSystem(root);
		const result = await syncback(root, fake);
		assert.equal(result.code, ExitCode.failure, String(message));
		assert.match(result.err, message);
		assert.deepEqual(fake.syncbacks(), []);
	}
});

test("a Hybrid project captures only opted-in trees that its start place also builds", async (t) => {
	const live = { name: "my-game", tree: { $className: "DataModel", ...CODE }, syncbackRules: RULES };
	const start = { name: "my-game", tree: { $className: "DataModel", ...CODE, Workspace: { $className: "Workspace", Baseplate: { $className: "Part" } } } };
	const none = await syncback(project(t, { tree: live, start }), fakeSystem(""));
	assert.equal(none.code, ExitCode.failure);
	assert.match(none.err, /maps no world content[\s\S]*Opt a subtree in by adding "Workspace"[\s\S]*start-place\.project\.json/);

	const optedIn = structuredClone(live);
	optedIn.tree.Workspace = { $className: "Workspace", Arenas: { $path: "world/Workspace/Arenas" } };
	const files = { "world/Workspace/Arenas/.gitkeep": "" };
	const unbuilt = await syncback(project(t, { tree: optedIn, start, files }), fakeSystem(""));
	assert.equal(unbuilt.code, ExitCode.failure);
	assert.match(unbuilt.err, /Workspace\/Arenas is captured into world\/Workspace\/Arenas, but start-place\.project\.json does not map it there/);

	const built = structuredClone(start);
	built.tree.Workspace.Arenas = { $path: "world/Workspace/Arenas" };
	const root = project(t, { tree: optedIn, start: built, files });
	const fake = fakeSystem(root, { plan: ["Writing world/Workspace/Arenas/Arena.model.json"], write: write("world/Workspace/Arenas/Arena.model.json", BASEPLATE) });
	const result = await syncback(root, fake);
	assert.equal(result.code, ExitCode.ok, result.err);
	assert.match(result.out, /Capturing my-game\.rbxl into default\.project\.json \(Hybrid project\)\.\nCaptured trees:\n {2}Workspace\/Arenas -> world\/Workspace\/Arenas\n/);
	assert.match(result.out, /Anything else in the place stays only in the place file/);
	assert.match(result.out, /created world\/Workspace\/Arenas\/Arena\.model\.json/);
});

test("syncback runs the pinned Rojo noninteractively, writing new instances as JSON models", async (t) => {
	const root = project(t);
	const fake = fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", ARENA(GENERATED)) });
	const result = await syncback(root, fake, ["--input", "my-game.rbxl"]);
	assert.equal(result.code, ExitCode.ok, result.err);

	const [dryRun, real] = fake.syncbacks();
	assert.deepEqual(dryRun.args, ["syncback", "default.project.json", "--input", path.join(root, "my-game.rbxl"), "--non-interactive", "--color", "never", "--dry-run", "--list"]);
	assert.deepEqual(real.args, dryRun.args.slice(0, -2));
	assert.equal(real.env.ROJO_SYNCBACK_DEBUG, "2");
});

test("a plan that reaches outside the captured folders writes nothing", async (t) => {
	const root = project(t);
	const fake = fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json", "Writing default.project.json", "Removing src\\server\\Startup.server.luau"] });
	const result = await syncback(root, fake);
	assert.equal(result.code, ExitCode.failure);
	assert.match(result.err, /outside the captured folders:\n {2}src\/server\/Startup\.server\.luau\nNothing was written/);
	assert.equal(fake.syncbacks().length, 1);
});

test("values Rojo would store in the project file stay in the place, and the capture names them", async (t) => {
	const root = project(t);
	const original = read(root, "default.project.json");
	const rewritten = structuredClone(FULL);
	rewritten.tree.Workspace.$properties = { Gravity: 50 };
	rewritten.tree.ServerScriptService.$attributes = { Owner: "Studio" };
	const fake = fakeSystem(root, {
		plan: ["Writing default.project.json", "Writing world/Workspace/Arena.model.json"],
		write: (directory) => {
			write("default.project.json", JSON.stringify(rewritten))(directory);
			write("world/Workspace/Arena.model.json", ARENA(GENERATED))(directory);
		},
	});
	const result = await syncback(root, fake);
	assert.equal(result.code, ExitCode.ok, result.err);
	assert.equal(read(root, "default.project.json"), original, "the project file is kept byte for byte");
	assert.match(result.out, /created world\/Workspace\/Arena\.model\.json\n/);
	assert.match(result.out, /Not captured, because default\.project\.json declares these instances; their values stay only in the place file:\n {2}ServerScriptService: attribute Owner\n {2}Workspace: Gravity\nSet them in default\.project\.json/);

	const onlyDeclared = fakeSystem(root, { plan: ["Writing default.project.json"], write: write("default.project.json", JSON.stringify(rewritten)) });
	const dryRun = await syncback(root, onlyDeclared, ["--dry-run"]);
	assert.match(dryRun.out, /default\.project\.json would be kept as it is[\s\S]*Nothing in the captured folders would change\.\nNothing was written \(--dry-run\)\.\n$/);
	const declaredOnly = await syncback(root, onlyDeclared);
	assert.equal(declaredOnly.code, ExitCode.ok, declaredOnly.err);
	assert.match(declaredOnly.out, /Workspace: Gravity\nSet them in default\.project\.json if they belong in source\.\nNo changes/);
	assert.equal(read(root, "default.project.json"), original);
});

test("a failed syncback is reported as a failure with Rojo's reason", async (t) => {
	const root = project(t);
	const duplicated = await syncback(root, fakeSystem(root, { fail: { message: "Failed to syncback because The child 'Arena' of 'Workspace' is duplicated in the place file." } }));
	assert.equal(duplicated.code, ExitCode.failure);
	assert.match(duplicated.err, /rojo syncback could not capture my-game\.rbxl:\nFailed to syncback because The child 'Arena'[\s\S]*Rename the duplicated instance/);
	assert.doesNotMatch(duplicated.out, /Captured \d/);

	const partial = await syncback(root, fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", "{}"), fail: { message: "disk full", dryRun: false } }));
	assert.equal(partial.code, ExitCode.failure);
	assert.match(partial.err, /disk full\nNothing was captured\. Fix the cause and run the command again\. Some files were already written; the previous files are in build\/krf\/syncback-[^/]+\/backup\./);
});

test("without Git, a capture copies the previous files to build/krf, reports exact changes and runs no git command", async (t) => {
	const root = project(t, { files: { "world/Workspace/Old.model.json": BASEPLATE } });
	const fake = fakeSystem(root, {
		plan: ["Writing world/Workspace/Arena.model.json", "Writing world/Workspace/Baseplate.model.json", "Removing world/Workspace/Old.model.json"],
		write: (directory) => {
			write("world/Workspace/Arena.model.json", ARENA(GENERATED))(directory);
			write("world/Workspace/Baseplate.model.json", '{\n  "className": "Part",\n  "properties": {\n    "Anchored": true\n  }\n}')(directory);
			fs.rmSync(path.join(directory, "world/Workspace/Old.model.json"));
		},
	});
	const result = await syncback(root, fake);
	assert.equal(result.code, ExitCode.ok, result.err);
	assert.deepEqual(
		fake.calls.filter((call) => call.command === "git"),
		[],
	);
	assert.match(result.out, /Captured 3 file changes:\n {2}created world\/Workspace\/Arena\.model\.json\n {2}changed world\/Workspace\/Baseplate\.model\.json\n {2}removed world\/Workspace\/Old\.model\.json\n/);
	assert.match(result.out, /The files as they were before this capture are in (build\/krf\/syncback-[^/]+\/backup)\.\nThis project has no Git repository/);
	assert.doesNotMatch(result.out, /git (status|diff)/);
	const backup = /are in (\S+)\.\n/.exec(result.out)[1];
	assert.equal(read(root, `${backup}/world/Workspace/Old.model.json`), BASEPLATE);
	assert.equal(read(root, `${backup}/world/Workspace/Baseplate.model.json`), BASEPLATE);
	assert.equal(read(root, "src/server/Startup.server.luau"), "print('hi')\n");

	const arena = JSON.parse(read(root, "world/Workspace/Arena.model.json"));
	assert.equal(arena.children[0].attributes.Rojo_Id, "Workspace/Arena/Floor");
	assert.deepEqual(Object.keys(arena.children[0].properties), ["Anchored", "Size"]);
	assert.match(read(root, "world/Workspace/Arena.model.json"), /4\.0/);
});

test("a second capture of an unchanged place leaves the source and build/krf as they were", async (t) => {
	const root = project(t);
	await syncback(root, fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", ARENA(GENERATED)) }));
	const captured = read(root, "world/Workspace/Arena.model.json");
	fs.rmSync(path.join(root, "build"), { recursive: true });

	const again = await syncback(root, fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", ARENA("5d175369ad720863caf1b59c00000000")) }));
	assert.equal(again.code, ExitCode.ok, again.err);
	assert.match(again.out, /No changes: the captured folders already match the saved place\.\n$/);
	assert.equal(read(root, "world/Workspace/Arena.model.json"), captured);
	assert.deepEqual(fs.readdirSync(path.join(root, "build", "krf")), []);

	const unchanged = await syncback(root, fakeSystem(root));
	assert.match(unchanged.out, /No changes/);
});

test("Git guards uncommitted work in the captured folders and gives review commands", async (t) => {
	const dirtyRoot = project(t, { git: true });
	const dirty = fakeSystem(dirtyRoot, { plan: ["Writing world/Workspace/Baseplate.model.json"], gitStatus: " M world/Workspace/Baseplate.model.json\0?? world/Workspace/New.model.json\0" });
	const refused = await syncback(dirtyRoot, dirty);
	assert.equal(refused.code, ExitCode.failure);
	assert.match(refused.err, /uncommitted changes[\s\S]*world\/Workspace\/Baseplate\.model\.json\n {2}world\/Workspace\/New\.model\.json\nCommit or stash them[\s\S]*--allow-dirty/);
	assert.equal(dirty.syncbacks().length, 1, "only the dry run ran");
	assert.deepEqual(dirty.calls.find((call) => call.command === "git").args, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--", "world/Workspace"]);

	const allowed = fakeSystem(dirtyRoot, {
		plan: ["Writing world/Workspace/Baseplate.model.json"],
		write: write("world/Workspace/Baseplate.model.json", '{\n  "className": "Part",\n  "properties": {\n    "Locked": true\n  }\n}'),
		gitStatus: " M world/Workspace/Baseplate.model.json\0",
	});
	const forced = await syncback(dirtyRoot, allowed, ["--allow-dirty"]);
	assert.equal(forced.code, ExitCode.ok, forced.err);
	assert.match(forced.out, /before this capture are in build\/krf\/syncback-/);

	const cleanRoot = project(t, { git: true });
	const clean = await syncback(cleanRoot, fakeSystem(cleanRoot, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", ARENA(GENERATED)) }));
	assert.equal(clean.code, ExitCode.ok, clean.err);
	assert.match(clean.out, /Review with git status -- world\/Workspace and git diff -- world\/Workspace, then commit\. Nothing was committed\.\nRebuild from source with npm run build/);
	assert.doesNotMatch(clean.out, /before this capture/);
	assert.equal(fs.existsSync(path.join(cleanRoot, "build")), false);

	const ignoredRoot = project(t, { git: true });
	const ignored = await syncback(ignoredRoot, fakeSystem(ignoredRoot, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", ARENA(GENERATED)), gitStatus: "!! world/Workspace/Baseplate.model.json\0" }));
	assert.match(ignored.out, /before this capture are in build\/krf\/syncback-/, "Git cannot restore ignored files, so they are backed up");

	const missingGitRoot = project(t, { git: true });
	const missingGit = await syncback(missingGitRoot, fakeSystem(missingGitRoot, { plan: ["Writing world/Workspace/Arena.model.json"], write: write("world/Workspace/Arena.model.json", "{}"), noGit: true }));
	assert.equal(missingGit.code, ExitCode.ok, missingGit.err);
	assert.match(missingGit.out, /before this capture are in build\/krf\/syncback-[\s\S]*no Git repository/);
});

test("--dry-run reports Rojo's plan without writing or checking Git", async (t) => {
	const root = project(t, { git: true });
	const fake = fakeSystem(root, { plan: ["Writing world/Workspace/Arena.model.json", "Removing world/Workspace/Baseplate.model.json"], gitStatus: " M world/Workspace/Baseplate.model.json\0" });
	const result = await syncback(root, fake, ["--dry-run"]);
	assert.equal(result.code, ExitCode.ok, result.err);
	assert.match(result.out, /a capture keeps any whose content does not change:\n {2}write world\/Workspace\/Arena\.model\.json\n {2}remove world\/Workspace\/Baseplate\.model\.json\nNothing was written \(--dry-run\)\.\n$/);
	assert.equal(fake.syncbacks().length, 1);
	assert.equal(fake.calls.some((call) => call.command === "git"), false);
	assert.equal(read(root, "world/Workspace/Baseplate.model.json"), BASEPLATE);
});
