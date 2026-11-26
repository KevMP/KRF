import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import { normalizeConfig, projectNameProblem, resolveProjectPath } from "../src/options.js";

const CWD = path.resolve("/workspace");

test("fills every value the caller omitted with the documented defaults", () => {
	assert.deepEqual(normalizeConfig({ projectPath: "my-game" }, CWD), {
		target: path.join(CWD, "my-game"),
		name: "my-game",
		options: { mode: "full", ci: true, agents: true },
		git: true,
	});
});

test("keeps explicit values, including false booleans", () => {
	const config = normalizeConfig(
		{ projectPath: "games/arena", mode: "hybrid", ci: false, agents: false, git: false },
		CWD,
	);
	assert.equal(config.target, path.join(CWD, "games", "arena"));
	assert.equal(config.name, "arena");
	assert.deepEqual(config.options, { mode: "hybrid", ci: false, agents: false });
	assert.equal(config.git, false);
});

test("rejects unsupported option values as usage errors", () => {
	for (const input of [{ mode: "studio" }]) {
		assert.throws(() => normalizeConfig({ projectPath: "my-game", ...input }, CWD), (error) => {
			assert.equal(error.code, "InvalidOption");
			assert.equal(error.exitCode, 2);
			assert.match(error.message, new RegExp(`--${Object.keys(input)[0]}`));
			return true;
		});
	}
});

test("accepts npm-style lowercase project names", () => {
	for (const name of ["my-game", "game2", "a", "rpg.client", "my_game"]) assert.equal(projectNameProblem(name), undefined, name);
});

test("rejects names that cannot be package and directory names", () => {
	for (const name of ["", "MyGame", "-game", ".game", "my game", "game!", "node_modules", "krf", "a".repeat(215)]) {
		assert.notEqual(projectNameProblem(name), undefined, name);
	}
});

test("refuses parent traversal, filesystem roots and a missing name", () => {
	assert.throws(() => resolveProjectPath("../outside", CWD), { code: "UnsafeProjectPath" });
	assert.throws(() => resolveProjectPath("games/../../outside", CWD), { code: "UnsafeProjectPath" });
	assert.throws(() => resolveProjectPath("games\\..\\x", CWD), { code: "UnsafeProjectPath" });
	assert.throws(() => resolveProjectPath(path.parse(CWD).root, CWD), { code: "UnsafeProjectPath" });
	assert.throws(() => resolveProjectPath("  ", CWD), { code: "ProjectNameMissing" });
	assert.throws(() => resolveProjectPath("Bad Name", CWD), { code: "InvalidProjectName" });
});
