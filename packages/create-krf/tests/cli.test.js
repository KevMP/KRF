import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KRF_RUNTIME, TOOLS_VERSION } from "krf-tools";

import { runCreator } from "../src/cli.js";
import { CREATOR_VERSION } from "../src/compatibility.js";

const CANCEL = Symbol("cancel");

function workspace(t) {
	const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-"));
	t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
	return cwd;
}

function recordingRunner(results = {}) {
	const calls = [];
	const run = (command, args, options) => {
		calls.push({ command, args, cwd: options.cwd });
		return results[`${command} ${args[0]}`] ?? { status: 0, stdout: "false\n", stderr: "" };
	};
	return { run, calls };
}

function scriptedPrompts(answers) {
	const asked = [];
	const answer = (options) => {
		asked.push(options.message);
		if (!(options.message in answers)) throw new Error(`Unexpected prompt: ${options.message}`);
		const value = answers[options.message];
		if (options.validate && value !== CANCEL) {
			const problem = options.validate(value);
			if (problem) throw new Error(`Validation failed: ${problem}`);
		}
		return Promise.resolve(value);
	};
	return {
		asked,
		prompts: { intro() {}, text: answer, select: answer, confirm: answer, isCancel: (value) => value === CANCEL },
	};
}

async function create(t, argv, options = {}) {
	const cwd = options.cwd ?? workspace(t);
	const runner = options.runner ?? recordingRunner();
	let stdout = "";
	let stderr = "";
	const code = await runCreator(argv, {
		cwd,
		interactive: options.prompts !== undefined,
		prompts: options.prompts,
		run: runner.run,
		stdout: (text) => (stdout += text),
		stderr: (text) => (stderr += text),
	});
	return { code, stdout, stderr, cwd, calls: runner.calls };
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

const BOOLEAN_FLAG = (name, value) => (value ? `--${name}` : `--no-${name}`);

const WIZARD_ANSWERS = (config) => ({
	"Project name": "my-game",
	"Project mode": config.mode,
	"Add a GitHub Actions workflow that checks and builds on every push and pull request?": config.ci,
});

const MATRIX = [];
for (const mode of ["full", "hybrid"]) for (const ci of [true, false]) MATRIX.push({ mode, ci });

const flagsFor = (config) => [
	"--mode",
	config.mode,
	BOOLEAN_FLAG("ci", config.ci),
	"--no-git",
];

test("--yes creates the default project without prompting", async (t) => {
	const result = await create(t, ["my-game", "--yes", "--no-git"]);
	assert.equal(result.code, 0, result.stderr);

	assert.deepEqual(Object.keys(readTree(path.join(result.cwd, "my-game"))).sort(), [
		".github/workflows/ci.yml",
		".gitignore",
		".vscode/extensions.json",
		".vscode/settings.json",
		"README.md",
		"default.project.json",
		"package.json",
		"rokit.toml",
		"scripts/setup.mjs",
		"selene.toml",
		"src/client/ActionInputPolicies/Focus.luau",
		"src/client/ActionInputPolicies/init.luau",
		"src/client/Controls/Keybinds.luau",
		"src/client/Controls/Loadout.luau",
		"src/client/Controls/init.luau",
		"src/client/EnergyDisplay.luau",
		"src/client/LocalCharacter.luau",
		"src/client/Startup.client.luau",
		"src/server/Actions/Focus.luau",
		"src/server/Actions/init.luau",
		"src/server/PlayerActors.luau",
		"src/server/Properties/EnergyRegen.luau",
		"src/server/Properties/init.luau",
		"src/server/Resources/Energy.luau",
		"src/server/Resources/init.luau",
		"src/server/Startup.server.luau",
		"src/server/Tags/Focused.luau",
		"src/server/Tags/init.luau",
		"src/shared/ActionRequests/Focus.luau",
		"src/shared/ActionRequests/init.luau",
		"src/shared/MergeDescendants.luau",
		"src/shared/RequireDescendants.luau",
		"stylua.toml",
		"tests/Definitions.spec.luau",
		"tests/jest.config.luau",
		"wally.toml",
	]);
	assert.match(result.stdout, /Created my-game/);
	assert.match(result.stdout, /Next:\n {2}cd my-game\n {2}npm install\n {2}npm run dev\n/);
	assert.deepEqual(result.calls, []);
});

test("the project's only npm dependency is the exact krf-tools release behind its workflow and generator scripts", async (t) => {
	const result = await create(t, ["my-game", "--yes", "--no-git"]);
	const manifest = JSON.parse(fs.readFileSync(path.join(result.cwd, "my-game", "package.json"), "utf8"));
	assert.equal(manifest.private, true);
	assert.equal(manifest.dependencies, undefined);
	assert.deepEqual(manifest.devDependencies, { "krf-tools": TOOLS_VERSION });
	assert.deepEqual(manifest.scripts, {
		postinstall: "node scripts/setup.mjs",
		dev: "krf-tools dev",
		build: manifest.scripts.build,
		test: "krf-tools test",
		"test:studio": "krf-tools test-studio",
		format: "stylua src tests",
		check: manifest.scripts.check,
		typecheck: manifest.scripts.typecheck,
		createAction: "krf-tools create action",
		createTag: "krf-tools create tag",
		createResource: "krf-tools create resource",
		createProperty: "krf-tools create property",
		createController: "krf-tools create controller",
		createCommand: "krf-tools create command",
		createHint: "krf-tools create hint",
		createDomain: "krf-tools create domain",
	});
	assert.doesNotMatch(JSON.stringify(manifest.scripts), /npx/);
});

test("the wizard and explicit flags create identical projects for every option combination", async (t) => {
	for (const config of MATRIX) {
		const flags = await create(t, ["my-game", ...flagsFor(config)]);
		const wizard = await create(t, [], { prompts: scriptedPrompts(WIZARD_ANSWERS(config)).prompts });

		assert.equal(flags.code, 0, flags.stderr);
		assert.equal(wizard.code, 0, wizard.stderr);

		const flagTree = readTree(path.join(flags.cwd, "my-game"));
		assert.deepEqual(readTree(path.join(wizard.cwd, "my-game")), flagTree, JSON.stringify(config));
		assert.equal(".github/workflows/ci.yml" in flagTree, config.ci);
		assert.equal("start-place.project.json" in flagTree, config.mode === "hybrid");
	}
});

test("the wizard asks only for values the command line did not supply", async (t) => {
	const { prompts, asked } = scriptedPrompts({ "Project mode": "hybrid" });
	const result = await create(t, ["arena", "--no-ci", "--no-git"], { prompts });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(asked, ["Project mode"]);

	const tree = readTree(path.join(result.cwd, "arena"));
	assert.ok("start-place.project.json" in tree);
	assert.ok(!(".github/workflows/ci.yml" in tree));
});

test("cancelling the wizard writes nothing", async (t) => {
	const { prompts } = scriptedPrompts({ "Project name": "my-game", "Project mode": CANCEL });
	const result = await create(t, [], { prompts });
	assert.equal(result.code, 130);
	assert.match(result.stderr, /cancelled\. No files were written/);
	assert.deepEqual(fs.readdirSync(result.cwd), []);
});

test("requires a project name when it cannot prompt", async (t) => {
	const result = await create(t, ["--mode", "hybrid"]);
	assert.equal(result.code, 2);
	assert.match(result.stderr, /project name is required when not running interactively/);
	assert.deepEqual(fs.readdirSync(result.cwd), []);
});

test("refuses an existing non-empty directory and leaves its contents alone", async (t) => {
	const cwd = workspace(t);
	fs.mkdirSync(path.join(cwd, "my-game"));
	fs.writeFileSync(path.join(cwd, "my-game", "notes.txt"), "mine");

	const result = await create(t, ["my-game", "--yes", "--no-git"], { cwd });
	assert.equal(result.code, 1);
	assert.match(result.stderr, /already exists and is not empty/);
	assert.deepEqual(fs.readdirSync(path.join(cwd, "my-game")), ["notes.txt"]);
	assert.equal(fs.readFileSync(path.join(cwd, "my-game", "notes.txt"), "utf8"), "mine");
});

test("rejects invalid names, unsafe paths and bad values before writing", async (t) => {
	for (const argv of [
		["My Game", "--yes"],
		["../escape", "--yes"],
		["my-game", "--yes", "--mode", "studio"],
		["my-game", "--yes", "--skip-install"],
		["my-game", "--yes", "--tooling", "minimal"],
		["my-game", "--yes", "--agents"],
		["my-game", "--yes", "--unknown"],
	]) {
		const result = await create(t, argv);
		assert.equal(result.code, 2, argv.join(" "));
		assert.notEqual(result.stderr, "", argv.join(" "));
		assert.deepEqual(fs.readdirSync(result.cwd), [], argv.join(" "));
	}
});

test("initializes Git inside the new project", async (t) => {
	const result = await create(t, ["my-game", "--yes"]);
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(result.calls, [
		{ command: "git", args: ["rev-parse", "--is-inside-work-tree"], cwd: result.cwd },
		{ command: "git", args: ["init", "--quiet"], cwd: path.join(result.cwd, "my-game") },
	]);
	assert.match(result.stdout, /git: done/);
});

test("does not create a nested repository inside an existing Git work tree", async (t) => {
	const runner = recordingRunner({ "git rev-parse": { status: 0, stdout: "true\n", stderr: "" } });
	const result = await create(t, ["my-game", "--yes"], { runner });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(
		result.calls.map((call) => call.args[0]),
		["rev-parse"],
	);
	assert.match(result.stdout, /git: skipped \(already inside a Git repository\)/);
});

test("keeps the complete project and fails visibly when git init fails", async (t) => {
	const runner = recordingRunner({ "git init": { status: 1, stdout: "", stderr: "fatal: no space" } });
	const result = await create(t, ["my-game", "--yes"], { runner });
	assert.equal(result.code, 1);
	assert.match(result.stderr, /Created .*my-game, but git failed: fatal: no space/);
	assert.match(result.stderr, /The project files are complete/);
	assert.equal(fs.existsSync(path.join(result.cwd, "my-game", "default.project.json")), true);
});

test("produces identical bytes for the same configuration", async (t) => {
	const first = await create(t, ["my-game", "--yes", "--mode", "hybrid", "--no-git"]);
	const second = await create(t, ["my-game", "--yes", "--mode", "hybrid", "--no-git"]);
	assert.deepEqual(readTree(path.join(first.cwd, "my-game")), readTree(path.join(second.cwd, "my-game")));
});

test("documents and workflows mention only npm scripts the project has", async (t) => {
	for (const config of MATRIX) {
		const result = await create(t, ["my-game", ...flagsFor(config)]);
		const tree = readTree(path.join(result.cwd, "my-game"));
		const scripts = Object.keys(JSON.parse(tree["package.json"]).scripts);
		const documents = ["README.md", ...(config.ci ? [".github/workflows/ci.yml"] : [])];

		for (const document of documents) {
			const mentioned = [...tree[document].matchAll(/npm run ([A-Za-z:]+)/g)].map((match) => match[1]);
			assert.deepEqual(
				mentioned.filter((script) => !scripts.includes(script)),
				[],
				`${document} ${JSON.stringify(config)}`,
			);
			if (/\bnpm test\b/.test(tree[document])) assert.ok(scripts.includes("test"), `${document} mentions npm test`);
			assert.doesNotMatch(tree[document], /npm ci\b|npm run packages:install|krf-tools|krf\.project\.json/, `${document} ${JSON.stringify(config)}`);
		}

		assert.match(tree["README.md"], new RegExp(`${KRF_RUNTIME.package}@${KRF_RUNTIME.version}`));
	}
});

test("--help documents the flags and --version prints the creator version", async (t) => {
	const help = await create(t, ["--help"]);
	assert.equal(help.code, 0);
	for (const flag of ["--mode", "--no-ci", "--no-git", "--yes"]) {
		assert.match(help.stdout, new RegExp(flag));
	}
	assert.doesNotMatch(help.stdout, /install/);

	const version = await create(t, ["--version"]);
	assert.equal(version.code, 0);
	assert.equal(version.stdout.trim(), CREATOR_VERSION);
});
