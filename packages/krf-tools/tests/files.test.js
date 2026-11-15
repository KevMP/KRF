import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KrfToolError, inspectTarget, writeNewDirectory } from "../src/index.js";

const FILES = new Map([
	["README.md", Buffer.from("# game\n")],
	["src/server/init.luau", Buffer.from("return {}\n")],
]);

function workspace(t) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-files-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	return root;
}

function listTree(root) {
	return fs
		.readdirSync(root, { recursive: true })
		.map((entry) => entry.split(path.sep).join("/"))
		.sort();
}

test("creates the target directory with every file", (t) => {
	const target = path.join(workspace(t), "game");
	writeNewDirectory(target, FILES);
	assert.deepEqual(listTree(target), ["README.md", "src", "src/server", "src/server/init.luau"]);
	assert.equal(fs.readFileSync(path.join(target, "src/server/init.luau"), "utf8"), "return {}\n");
	assert.deepEqual(fs.readdirSync(path.dirname(target)), ["game"]);
});

test("accepts an existing empty directory and creates missing parents", (t) => {
	const root = workspace(t);
	fs.mkdirSync(path.join(root, "empty"));
	writeNewDirectory(path.join(root, "empty"), FILES);
	writeNewDirectory(path.join(root, "nested", "deeper", "game"), FILES);
	assert.equal(fs.existsSync(path.join(root, "empty", "README.md")), true);
	assert.equal(fs.existsSync(path.join(root, "nested", "deeper", "game", "README.md")), true);
});

test("refuses a non-empty directory or a file without changing it", (t) => {
	const root = workspace(t);
	fs.mkdirSync(path.join(root, "existing"));
	fs.writeFileSync(path.join(root, "existing", "keep.txt"), "mine");
	fs.writeFileSync(path.join(root, "file"), "mine");

	assert.throws(() => writeNewDirectory(path.join(root, "existing"), FILES), { code: "TargetNotEmpty" });
	assert.throws(() => writeNewDirectory(path.join(root, "file"), FILES), { code: "TargetNotDirectory" });
	assert.deepEqual(listTree(root), ["existing", "existing/keep.txt", "file"]);
	assert.equal(fs.readFileSync(path.join(root, "existing", "keep.txt"), "utf8"), "mine");
});

test("rejects output paths that escape the project", (t) => {
	const target = path.join(workspace(t), "game");
	for (const relative of ["../escape.txt", "/abs.txt", "C:\\abs.txt", "a/../b.txt", "./a.txt", ""]) {
		assert.throws(() => writeNewDirectory(target, new Map([[relative, "x"]])), { code: "UnsafeOutputPath" }, relative);
	}
	assert.equal(fs.existsSync(target), false);
});

test("leaves nothing behind when a write fails part way", (t) => {
	const root = workspace(t);
	fs.writeFileSync(path.join(root, "sibling.txt"), "mine");
	let writes = 0;
	const fileSystem = {
		...fs,
		writeFileSync(file, contents, options) {
			writes += 1;
			if (writes === 2) throw Object.assign(new Error("disk full"), { code: "ENOSPC" });
			return fs.writeFileSync(file, contents, options);
		},
	};

	assert.throws(() => writeNewDirectory(path.join(root, "new", "game"), FILES, { fileSystem }), (error) => {
		assert.ok(error instanceof KrfToolError);
		assert.equal(error.code, "WriteFailed");
		assert.match(error.message, /disk full/);
		return true;
	});
	assert.deepEqual(listTree(root), ["sibling.txt"]);
});

test("does not replace a target that appears while files are staged", (t) => {
	const root = workspace(t);
	const target = path.join(root, "game");
	let created = false;
	const fileSystem = {
		...fs,
		writeFileSync(file, contents, options) {
			if (!created) {
				created = true;
				fs.mkdirSync(target);
				fs.writeFileSync(path.join(target, "theirs.txt"), "theirs");
			}
			return fs.writeFileSync(file, contents, options);
		},
	};

	assert.throws(() => writeNewDirectory(target, FILES, { fileSystem }), { code: "TargetNotEmpty" });
	assert.deepEqual(listTree(root), ["game", "game/theirs.txt"]);
});

test("reports whether a usable target already exists", (t) => {
	const root = workspace(t);
	assert.deepEqual(inspectTarget(path.join(root, "absent")), { exists: false });
	fs.mkdirSync(path.join(root, "empty"));
	assert.deepEqual(inspectTarget(path.join(root, "empty")), { exists: true });
});
