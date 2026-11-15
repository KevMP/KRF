import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { ExitCode, PROJECT_METADATA_FILE, TOOLING_VERSION, runCli, serializeProjectMetadata } from "../src/index.js";

function metadata(toolingVersion = TOOLING_VERSION) {
	return {
		metadataVersion: 1,
		name: "my-game",
		options: { mode: "hybrid", tooling: "minimal", ci: false, agents: true },
		creator: { name: "create-krf", version: "0.1.0" },
		template: { version: "0.1.0" },
		runtime: { package: "kevmp/krf", version: "0.1.0" },
		tooling: { package: "krf-tools", version: toolingVersion },
	};
}

async function run(t, argv, contents) {
	const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "krf-cli-"));
	t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
	if (contents !== undefined) fs.writeFileSync(path.join(cwd, PROJECT_METADATA_FILE), contents);

	let stdout = "";
	let stderr = "";
	const code = await runCli(argv, { cwd, stdout: (text) => (stdout += text), stderr: (text) => (stderr += text) });
	return { code, stdout, stderr };
}

test("info shows the project's options and pinned versions", async (t) => {
	const result = await run(t, ["info"], serializeProjectMetadata(metadata()));
	assert.equal(result.code, ExitCode.ok);
	assert.match(result.stdout, /^my-game\n/);
	assert.match(result.stdout, /Mode: {6}hybrid/);
	assert.match(result.stdout, /KRF: {7}kevmp\/krf@0\.1\.0/);
	assert.equal(result.stderr, "");
});

test("info --json prints the validated metadata for agents", async (t) => {
	const result = await run(t, ["info", "--json"], serializeProjectMetadata(metadata()));
	assert.equal(result.code, ExitCode.ok);
	assert.deepEqual(JSON.parse(result.stdout), { ok: true, project: metadata() });
});

test("info fails with guidance outside a KRF project", async (t) => {
	const result = await run(t, ["info"]);
	assert.equal(result.code, ExitCode.failure);
	assert.match(result.stderr, /No krf\.project\.json/);
	assert.match(result.stderr, /project created by create-krf/);
});

test("info fails when the installed tooling differs from the pinned version", async (t) => {
	const result = await run(t, ["info"], serializeProjectMetadata(metadata("9.9.9")));
	assert.equal(result.code, ExitCode.failure);
	assert.match(result.stderr, /pins krf-tools 9\.9\.9, but .* is installed/);
	assert.match(result.stderr, /npm install/);
});

test("an unavailable command fails as a usage error and lists available commands", async (t) => {
	const result = await run(t, ["createAction", "--name", "Fireball"]);
	assert.equal(result.code, ExitCode.usage);
	assert.match(result.stderr, new RegExp(`krf-tools ${TOOLING_VERSION.replace(/\./g, "\\.")} has no 'createAction' command`));
	assert.match(result.stderr, /Available commands: info/);
});

test("--version and --help exit successfully", async (t) => {
	const version = await run(t, ["--version"]);
	assert.equal(version.code, ExitCode.ok);
	assert.equal(version.stdout.trim(), TOOLING_VERSION);

	const help = await run(t, ["--help"]);
	assert.equal(help.code, ExitCode.ok);
	assert.match(help.stdout, /Use the npm scripts in package\.json/);
	assert.match(help.stdout, /info/);
});

test("an unknown option is a usage error", async (t) => {
	const result = await run(t, ["info", "--nope"], serializeProjectMetadata(metadata()));
	assert.equal(result.code, ExitCode.usage);
	assert.match(result.stderr, /unknown option '--nope'/);
});
