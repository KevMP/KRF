import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { startAutoCapture } from "../src/assets/watch.js";
import { readLocalProject } from "../src/workflow/project.js";

const RULES = { ignoreTrees: ["ServerScriptService/Game"] };
const FULL = {
	name: "my-game",
	tree: {
		$className: "DataModel",
		ServerScriptService: { $className: "ServerScriptService", Game: { $path: "src/server" } },
		Workspace: { $className: "Workspace", $ignoreUnknownInstances: true, $path: "world/Workspace" },
	},
	syncbackRules: RULES,
};
const SETTLE_MS = 30;

function project(t, tree = FULL) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-watch-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	for (const [file, contents] of Object.entries({
		"package.json": JSON.stringify({ name: "my-game" }),
		"wally.toml": "",
		"default.project.json": JSON.stringify(tree),
		"world/Workspace/.gitkeep": "",
		"src/server/Startup.server.luau": "",
		"my-game.rbxl": "saved 0",
	})) {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), contents);
	}
	return root;
}

function harness(root, { fail = false } = {}) {
	const io = { out: "", err: "" };
	let listener;
	let closed = false;
	let captures = 0;
	const system = {
		platform: "linux",
		env: {},
		spawnSync(command, args) {
			if (args[0] === "--version") return { status: 0, stdout: "Rojo 7.7.1\n", stderr: "" };
			if (args.includes("--dry-run")) {
				const saved = fs.readFileSync(path.join(root, "my-game.rbxl"), "utf8");
				return { status: 0, stdout: saved === "saved 0" ? "" : `Writing ${path.join(root, "world/Workspace/Arena.model.json")}\n`, stderr: "" };
			}
			if (fail) return { status: 1, stdout: "", stderr: "[ERROR rojo] the place file is truncated" };
			captures += 1;
			fs.writeFileSync(path.join(root, "world/Workspace/Arena.model.json"), `{\n  "className": "Model",\n  "attributes": {\n    "Saves": ${captures}.0\n  }\n}`);
			return { status: 0, stdout: "", stderr: "" };
		},
	};
	const watch = (directory, callback) => {
		assert.equal(directory, root);
		listener = callback;
		return { close: () => (closed = true) };
	};
	const started = startAutoCapture(system, readLocalProject(root), path.join(root, "my-game.rbxl"), { stdout: (text) => (io.out += text), stderr: (text) => (io.err += text) }, { settleMs: SETTLE_MS, watch });
	return {
		io,
		started,
		captures: () => captures,
		closed: () => closed,
		async save(contents) {
			fs.writeFileSync(path.join(root, "my-game.rbxl"), contents);
			listener("change", "my-game.rbxl");
			listener("change", "my-game.rbxl.lock");
			listener("rename", "my-game.rbxl");
			await new Promise((resolve) => setTimeout(resolve, SETTLE_MS * 4));
		},
	};
}

test("each Studio save is captured once, after the file settles", async (t) => {
	const root = project(t);
	const watcher = harness(root);
	assert.match(watcher.io.out, /Saving my-game\.rbxl in Studio captures world\/Workspace automatically; npm run dev -- --no-capture turns this off/);

	await watcher.save("saved 1");
	assert.equal(watcher.captures(), 1);
	assert.match(watcher.io.out, /Studio saved my-game\.rbxl; capturing it\.\nCaptured 1 file change:\n {2}created world\/Workspace\/Arena\.model\.json\n/);
	assert.match(watcher.io.out, /The files as they were before this session's first capture are in build\/krf\/syncback-/);

	await watcher.save("saved 2");
	assert.equal(watcher.captures(), 2);
	assert.match(fs.readFileSync(path.join(root, "world/Workspace/Arena.model.json"), "utf8"), /"Saves": 2\.0/);
	assert.equal(watcher.io.out.match(/before this session's first capture/g).length, 1, "only the first capture of a session is backed up");

	await watcher.save("saved 0");
	assert.match(watcher.io.out, /nothing new to capture/);
	watcher.started.stop();
	assert.equal(watcher.closed(), true);
	await watcher.save("saved 3");
	assert.equal(watcher.captures(), 2, "no capture runs after dev stops");
});

test("a save after captured files changed on disk is skipped, so hand edits are never overwritten", async (t) => {
	const root = project(t);
	const watcher = harness(root);
	t.after(() => watcher.started.stop());
	fs.writeFileSync(path.join(root, "world/Workspace/Hand.model.json"), "{}");
	await watcher.save("saved 1");
	assert.equal(watcher.captures(), 0);
	assert.match(watcher.io.out, /but world\/Workspace\/Hand\.model\.json changed on disk since the last capture, so this save was not captured/);
	assert.equal(fs.readFileSync(path.join(root, "world/Workspace/Hand.model.json"), "utf8"), "{}");

	await watcher.save("saved 2");
	assert.equal(watcher.captures(), 1, "the next save captures again");
});

test("a failed capture is reported and later saves are still captured", async (t) => {
	const root = project(t);
	const failing = harness(root, { fail: true });
	t.after(() => failing.started.stop());
	await failing.save("saved 1");
	assert.match(failing.io.err, /Capturing the save failed: rojo syncback could not capture my-game\.rbxl:\nthe place file is truncated/);
	assert.equal(fs.existsSync(path.join(root, "world/Workspace/Arena.model.json")), false);
});

test("auto-capture stays off when nothing is mapped or Rojo cannot capture", async (t) => {
	const root = project(t, { name: "my-game", tree: { $className: "DataModel", ServerScriptService: FULL.tree.ServerScriptService }, syncbackRules: RULES });
	let watched = false;
	const io = { out: "" };
	const off = startAutoCapture({ platform: "linux", env: {}, spawnSync: () => ({ status: 0, stdout: "Rojo 7.7.1", stderr: "" }) }, readLocalProject(root), path.join(root, "my-game.rbxl"), { stdout: (text) => (io.out += text) }, {
		watch: () => {
			watched = true;
		},
	});
	off.stop();
	assert.equal(watched, false);
	assert.match(io.out, /Saving in Studio does not capture the world: default\.project\.json maps no world content/);

	const old = project(t);
	const oldIo = { out: "" };
	startAutoCapture({ platform: "linux", env: {}, spawnSync: () => ({ status: 0, stdout: "Rojo 7.6.1", stderr: "" }) }, readLocalProject(old), path.join(old, "my-game.rbxl"), { stdout: (text) => (oldIo.out += text) }, { watch: () => assert.fail("must not watch") });
	assert.match(oldIo.out, /does not capture the world: npm run assets:syncback needs Rojo 7\.7\.1 or newer/);
});
