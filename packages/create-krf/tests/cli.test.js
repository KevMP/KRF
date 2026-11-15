import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { readProjectMetadata } from "krf-tools";

import { runCreator } from "../src/cli.js";
import { CREATOR_VERSION, KRF_RUNTIME, KRF_TOOLING } from "../src/compatibility.js";

const CANCEL = Symbol("cancel");

function workspace(t) {
	const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-"));
	t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
	return cwd;
}

/** Records process invocations; `results` maps "command arg0" to a result. */
function recordingRunner(results = {}) {
	const calls = [];
	const run = (command, args, options) => {
		calls.push({ command, args, cwd: options.cwd });
		return results[`${command} ${args[0]}`] ?? { status: 0, stdout: command === "git" ? "false\n" : "", stderr: "" };
	};
	return { run, calls };
}

/** A @clack/prompts stand-in answering by message; it records every question asked. */
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
	"Developer tooling": config.tooling,
	"Add a GitHub Actions workflow?": config.ci,
	"Add instructions for AI coding agents?": config.agents,
	"Initialize a Git repository?": false,
	"Install npm dependencies?": false,
});

const MATRIX = [];
for (const mode of ["full", "hybrid"])
	for (const tooling of ["standard", "minimal"])
		for (const ci of [true, false]) for (const agents of [true, false]) MATRIX.push({ mode, tooling, ci, agents });

test("--yes creates the default project without prompting", async (t) => {
	const result = await create(t, ["my-game", "--yes", "--skip-install", "--no-git"]);
	assert.equal(result.code, 0, result.stderr);

	const project = path.join(result.cwd, "my-game");
	assert.deepEqual(Object.keys(readTree(project)).sort(), [
		".github/workflows/ci.yml",
		".gitignore",
		"AGENTS.md",
		"README.md",
		"krf.project.json",
		"package.json",
	]);
	assert.deepEqual(readProjectMetadata(project), {
		metadataVersion: 1,
		name: "my-game",
		options: { mode: "full", tooling: "standard", ci: true, agents: true },
		creator: { name: "create-krf", version: CREATOR_VERSION },
		template: { version: CREATOR_VERSION },
		runtime: KRF_RUNTIME,
		tooling: KRF_TOOLING,
	});
	assert.match(result.stdout, /Created my-game/);
	assert.match(result.stdout, /npm run project:info/);
	assert.deepEqual(result.calls, []);
});

test("declares the pinned tooling and only scripts it implements", async (t) => {
	const result = await create(t, ["my-game", "--yes", "--skip-install", "--no-git"]);
	const manifest = JSON.parse(fs.readFileSync(path.join(result.cwd, "my-game", "package.json"), "utf8"));
	assert.deepEqual(manifest.devDependencies, { "krf-tools": KRF_TOOLING.version });
	assert.deepEqual(manifest.scripts, { "project:info": "krf-tools info" });
	assert.equal(manifest.private, true);
});

test("the wizard and explicit flags create identical projects for every option combination", async (t) => {
	for (const config of MATRIX) {
		const flags = await create(t, [
			"my-game",
			"--mode",
			config.mode,
			"--tooling",
			config.tooling,
			BOOLEAN_FLAG("ci", config.ci),
			BOOLEAN_FLAG("agents", config.agents),
			"--no-git",
			"--skip-install",
		]);
		const wizard = await create(t, [], { prompts: scriptedPrompts(WIZARD_ANSWERS(config)).prompts });

		assert.equal(flags.code, 0, flags.stderr);
		assert.equal(wizard.code, 0, wizard.stderr);

		const flagTree = readTree(path.join(flags.cwd, "my-game"));
		assert.deepEqual(readTree(path.join(wizard.cwd, "my-game")), flagTree, JSON.stringify(config));
		assert.equal(".github/workflows/ci.yml" in flagTree, config.ci);
		assert.equal("AGENTS.md" in flagTree, config.agents);
		assert.deepEqual(JSON.parse(flagTree["krf.project.json"]).options, config);
	}
});

test("the wizard asks only for values the command line did not supply", async (t) => {
	const { prompts, asked } = scriptedPrompts({ "Project mode": "hybrid", "Install npm dependencies?": false });
	const result = await create(t, ["arena", "--tooling", "minimal", "--no-ci", "--agents", "--no-git"], { prompts });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(asked, ["Project mode", "Install npm dependencies?"]);
	assert.deepEqual(readProjectMetadata(path.join(result.cwd, "arena")).options, {
		mode: "hybrid",
		tooling: "minimal",
		ci: false,
		agents: true,
	});
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

	const result = await create(t, ["my-game", "--yes", "--skip-install", "--no-git"], { cwd });
	assert.equal(result.code, 1);
	assert.match(result.stderr, /already exists and is not empty/);
	assert.deepEqual(fs.readdirSync(path.join(cwd, "my-game")), ["notes.txt"]);
	assert.equal(fs.readFileSync(path.join(cwd, "my-game", "notes.txt"), "utf8"), "mine");
});

test("rejects invalid names, unsafe paths, bad values and conflicting flags before writing", async (t) => {
	for (const argv of [
		["My Game", "--yes"],
		["../escape", "--yes"],
		["my-game", "--yes", "--mode", "studio"],
		["my-game", "--yes", "--install", "--skip-install"],
		["my-game", "--yes", "--unknown"],
	]) {
		const result = await create(t, argv);
		assert.equal(result.code, 2, argv.join(" "));
		assert.notEqual(result.stderr, "", argv.join(" "));
		assert.deepEqual(fs.readdirSync(result.cwd), [], argv.join(" "));
	}
});

test("initializes Git and installs dependencies inside the new project", async (t) => {
	const result = await create(t, ["my-game", "--yes"]);
	const project = path.join(result.cwd, "my-game");
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(result.calls, [
		{ command: "git", args: ["rev-parse", "--is-inside-work-tree"], cwd: result.cwd },
		{ command: "git", args: ["init", "--quiet"], cwd: project },
		{ command: "npm", args: ["install", "--no-audit", "--no-fund"], cwd: project },
	]);
	assert.match(result.stdout, /git: done/);
	assert.match(result.stdout, /install: done/);
});

test("does not create a nested repository inside an existing Git work tree", async (t) => {
	const runner = recordingRunner({ "git rev-parse": { status: 0, stdout: "true\n", stderr: "" } });
	const result = await create(t, ["my-game", "--yes", "--skip-install"], { runner });
	assert.equal(result.code, 0, result.stderr);
	assert.deepEqual(
		result.calls.map((call) => call.args[0]),
		["rev-parse"],
	);
	assert.match(result.stdout, /git: skipped \(already inside a Git repository\)/);
});

test("keeps the complete project and fails visibly when a setup step fails", async (t) => {
	const runner = recordingRunner({ "npm install": { status: 1, stdout: "", stderr: "ERR! network down" } });
	const result = await create(t, ["my-game", "--yes", "--no-git"], { runner });
	assert.equal(result.code, 1);
	assert.match(result.stderr, /Created .*my-game, but install failed: ERR! network down/);
	assert.match(result.stderr, /The project files are complete/);
	assert.equal(fs.existsSync(path.join(result.cwd, "my-game", "krf.project.json")), true);
});

test("produces identical bytes for the same configuration", async (t) => {
	const first = await create(t, ["my-game", "--yes", "--mode", "hybrid", "--skip-install", "--no-git"]);
	const second = await create(t, ["my-game", "--yes", "--mode", "hybrid", "--skip-install", "--no-git"]);
	assert.deepEqual(readTree(path.join(first.cwd, "my-game")), readTree(path.join(second.cwd, "my-game")));
});

test("describes the generated shell honestly", async (t) => {
	const result = await create(t, ["my-game", "--yes", "--skip-install", "--no-git"]);
	const readme = fs.readFileSync(path.join(result.cwd, "my-game", "README.md"), "utf8");
	assert.match(readme, /does not yet include a Rojo project, Wally dependencies or game code/);
	assert.match(readme, new RegExp(`${KRF_RUNTIME.package}@${KRF_RUNTIME.version}`));
	assert.doesNotMatch(readme, /npm run (dev|build|test)\b/);
});

test("--help documents the flags and --version prints the creator version", async (t) => {
	const help = await create(t, ["--help"]);
	assert.equal(help.code, 0);
	for (const flag of ["--mode", "--tooling", "--no-ci", "--no-agents", "--skip-install", "--no-git", "--yes"]) {
		assert.match(help.stdout, new RegExp(flag));
	}

	const version = await create(t, ["--version"]);
	assert.equal(version.code, 0);
	assert.equal(version.stdout.trim(), CREATOR_VERSION);
});
