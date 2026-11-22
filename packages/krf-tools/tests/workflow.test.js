import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { ExitCode } from "../src/errors.js";
import { runWorkflow } from "../src/workflow/cli.js";
import { deriveProject, readLocalProject } from "../src/workflow/project.js";
import { between, placeOpenInStudio, readMarker, resolveStudio } from "../src/workflow/studio.js";

const LOCK = '[[package]]\nname = "kevmp/krf"\nversion = "0.2.0"\n';

function project(t, { hybrid = false, files = {} } = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-workflow-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const tree = { $className: "DataModel", ReplicatedStorage: { $className: "ReplicatedStorage", Packages: { $path: "Packages" } } };
	const all = {
		"package.json": JSON.stringify({ name: "my-game" }),
		"wally.toml": '[dependencies]\nKRF = "kevmp/krf@=0.2.0"\n',
		"wally.lock": LOCK,
		"default.project.json": JSON.stringify({ name: "my-game", tree }),
		...(hybrid ? { "start-place.project.json": JSON.stringify({ name: "my-game", tree }) } : {}),
		...files,
	};
	for (const [file, contents] of Object.entries(all)) {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), contents);
	}
	return root;
}

function capture() {
	const io = { out: "", err: "" };
	return Object.assign(io, { stdout: (text) => (io.out += text), stderr: (text) => (io.err += text) });
}

function fakeChild() {
	const child = new EventEmitter();
	child.stdout = new EventEmitter();
	child.stderr = new EventEmitter();
	child.pid = 4242;
	child.killed = false;
	child.kill = () => {
		child.killed = true;
		setImmediate(() => child.emit("exit", null));
	};
	child.unref = () => {};
	return child;
}

function fakeSystem({ onSpawn } = {}) {
	const calls = { spawnSync: [], spawn: [] };
	let interrupt;
	const system = {
		platform: "win32",
		env: {},
		spawnSync(command, args) {
			calls.spawnSync.push([command, ...args]);
			if (command === "rojo" && args[0] === "build") fs.writeFileSync(args[3], "place");
			return { status: 0, stdout: "", stderr: "" };
		},
		spawn(command, args) {
			calls.spawn.push([command, ...args]);
			const child = fakeChild();
			onSpawn?.(command, args, child);
			return child;
		},
		onInterrupt(handler) {
			interrupt = handler;
			return () => {};
		},
	};
	return { system, calls, interrupt: () => interrupt() };
}

async function freePort() {
	const server = net.createServer();
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	const { port } = server.address();
	await new Promise((resolve) => server.close(resolve));
	return port;
}

test("readLocalProject detects Full and Hybrid projects and their Studio place", (t) => {
	const full = readLocalProject(project(t));
	assert.equal(full.mode, "full");
	assert.equal(path.basename(full.place), "my-game.rbxl");
	assert.equal(path.basename(full.placeProject), "default.project.json");

	const hybrid = readLocalProject(project(t, { hybrid: true }));
	assert.equal(hybrid.mode, "hybrid");
	assert.equal(path.basename(hybrid.placeProject), "start-place.project.json");
	assert.equal(path.basename(hybrid.codeProject), "default.project.json");
});

test("a derived test project points every $path back at the game's source", (t) => {
	const root = project(t);
	const local = readLocalProject(root);
	const directory = path.join(root, "build", "krf", "run");
	const file = deriveProject(local, directory, (tree) => {
		tree.ReplicatedStorage.Extra = { $path: "Extra.luau" };
	});
	const derived = JSON.parse(fs.readFileSync(file, "utf8"));
	assert.equal(derived.tree.ReplicatedStorage.Packages.$path, "../../../Packages");
	assert.equal(derived.tree.ReplicatedStorage.Extra.$path, "Extra.luau");
});

test("Studio results are read only from exact marker lines", () => {
	const log = ['> print("__KRF_TEST_RESULT__ " .. x)', "__KRF_TEST_OUTPUT_BEGIN__", "PASS a", "__KRF_TEST_OUTPUT_END__", '__KRF_TEST_RESULT__ {"numTotalTests":1}', "__KRF_X__ {bad"].join("\r\n");
	assert.deepEqual(readMarker(log, "TEST_RESULT"), { numTotalTests: 1 });
	assert.equal(readMarker(log, "X"), undefined);
	assert.deepEqual(between(log, "__KRF_TEST_OUTPUT_BEGIN__", "__KRF_TEST_OUTPUT_END__"), ["PASS a"]);
});

test("Studio is found from --studio-path or the Windows registry, and a missing one is reported", (t) => {
	const root = project(t, { files: { "Studio/RobloxStudioBeta.exe": "" } });
	const studio = path.join(root, "Studio", "RobloxStudioBeta.exe");
	assert.equal(resolveStudio({ platform: "linux" }, studio), studio);
	assert.throws(() => resolveStudio({ platform: "win32" }, path.join(root, "missing.exe")), { code: "StudioNotFound" });

	const registry = { platform: "win32", env: { LOCALAPPDATA: root }, spawnSync: () => ({ status: 0, stdout: `\r\n    (Default)    REG_SZ    "${studio}" %1\r\n` }) };
	assert.equal(resolveStudio(registry), studio);
	assert.throws(() => resolveStudio({ platform: "linux", env: {} }), { code: "StudioUnsupported" });
});

test("a place counts as open in Studio only while Studio holds its lock", (t) => {
	const root = project(t, { files: { "my-game.rbxl.lock": "" } });
	assert.equal(placeOpenInStudio({ platform: "win32" }, path.join(root, "my-game.rbxl")), false);
	assert.equal(placeOpenInStudio({ platform: "darwin" }, path.join(root, "my-game.rbxl")), true);
	assert.equal(placeOpenInStudio({ platform: "win32" }, path.join(root, "other.rbxl")), false);
});

test("npm test reports missing tests and a missing Jest install without starting Studio", async (t) => {
	const { system, calls } = fakeSystem();
	const empty = capture();
	assert.equal(await runWorkflow(["test"], { cwd: project(t), ...empty }, system), ExitCode.testsNotConfigured);
	assert.match(empty.err, /No tests are configured/);

	const noJest = capture();
	const root = project(t, { files: { "tests/A.spec.luau": "", "tests/jest.config.luau": "return {}" } });
	assert.equal(await runWorkflow(["test"], { cwd: root, ...noJest }, system), ExitCode.failure);
	assert.match(noJest.err, /Jest is not installed[\s\S]*Jest = "jsdotlua\/jest@/);
	assert.deepEqual(calls.spawn, []);
});

test("invalid options are usage errors", async (t) => {
	const { system } = fakeSystem();
	for (const argv of [["dev", "--port", "0"], ["test-studio", "--clients", "9"], ["test", "--timeout", "soon"]]) {
		const io = capture();
		assert.equal(await runWorkflow(argv, { cwd: project(t), ...io }, system), ExitCode.usage, argv.join(" "));
		assert.match(io.err, /Invalid --/);
	}
});

test("npm run dev builds a Full place, serves it and stops only Rojo on Ctrl+C", async (t) => {
	const root = project(t);
	const port = await freePort();
	const fake = fakeSystem({
		onSpawn: (command, args, child) => {
			if (command === "rojo") setImmediate(() => child.stdout.emit("data", Buffer.from(`Rojo server listening:\n  Port:    \x1b[32m${args[3]}\x1b[0m\n`)));
		},
	});
	const io = capture();
	const running = runWorkflow(["dev", "--no-open", "--port", String(port)], { cwd: root, ...io }, fake.system);
	await new Promise((resolve) => setTimeout(resolve, 50));
	assert.match(io.out, new RegExp(`Rojo is serving default\\.project\\.json on localhost:${port}`));
	fake.interrupt();
	assert.equal(await running, ExitCode.ok);

	assert.deepEqual(fake.calls.spawnSync, [["rojo", "build", path.join(root, "default.project.json"), "--output", path.join(root, "my-game.rbxl")]]);
	assert.deepEqual(fake.calls.spawn, [["rojo", "serve", "default.project.json", "--port", String(port)]]);
	assert.match(io.out, /Built my-game\.rbxl from default\.project\.json/);
	assert.match(io.out, /Open my-game\.rbxl in Roblox Studio/);
});

test("npm run dev creates a Hybrid place once and never rebuilds it", async (t) => {
	const root = project(t, { hybrid: true });
	const port = await freePort();
	for (const expected of [/Created my-game\.rbxl from start-place\.project\.json/, /Using your Studio place my-game\.rbxl; npm run dev never rebuilds it/]) {
		const fake = fakeSystem({ onSpawn: (command, args, child) => setImmediate(() => child.stdout.emit("data", Buffer.from(`Port: ${args[3]}\n`))) });
		const io = capture();
		const running = runWorkflow(["dev", "--no-open", "--port", String(port)], { cwd: root, ...io }, fake.system);
		await new Promise((resolve) => setTimeout(resolve, 50));
		fake.interrupt();
		assert.equal(await running, ExitCode.ok);
		assert.match(io.out, expected);
	}
	assert.equal(fs.readFileSync(path.join(root, "my-game.rbxl"), "utf8"), "place");
});

test("npm run dev refuses a busy port, --place in Full mode and a missing Hybrid place", async (t) => {
	const server = net.createServer();
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	t.after(() => server.close());
	const busy = capture();
	assert.equal(await runWorkflow(["dev", "--no-open", "--port", String(server.address().port)], { cwd: project(t), ...busy }, fakeSystem().system), ExitCode.failure);
	assert.match(busy.err, /is already in use/);

	const port = await freePort();
	const full = capture();
	assert.equal(await runWorkflow(["dev", "--no-open", "--port", String(port), "--place", "x.rbxl"], { cwd: project(t), ...full }, fakeSystem().system), ExitCode.usage);

	const missing = capture();
	assert.equal(await runWorkflow(["dev", "--no-open", "--port", String(port), "--place", "World.rbxl"], { cwd: project(t, { hybrid: true }), ...missing }, fakeSystem().system), ExitCode.failure);
	assert.match(missing.err, /World\.rbxl does not exist/);
});

test("npm run dev fails when rojo serve exits before it is ready", async (t) => {
	const port = await freePort();
	const fake = fakeSystem({ onSpawn: (command, args, child) => setImmediate(() => child.emit("exit", 1)) });
	const io = capture();
	assert.equal(await runWorkflow(["dev", "--no-open", "--port", String(port)], { cwd: project(t), ...io }, fake.system), ExitCode.failure);
	assert.match(io.err, /rojo serve exited with code 1 before it was ready/);
});

test("npm run dev captures Studio saves of mapped world folders unless --no-capture is passed", async (t) => {
	const tree = { $className: "DataModel", Workspace: { $className: "Workspace", $ignoreUnknownInstances: true, $path: "world/Workspace" } };
	for (const [flags, expected] of [
		[[], /Saving my-game\.rbxl in Studio captures world\/Workspace automatically/],
		[["--no-capture"], undefined],
	]) {
		const root = project(t, { files: { "default.project.json": JSON.stringify({ name: "my-game", tree }), "world/Workspace/.gitkeep": "" } });
		const port = await freePort();
		const watched = [];
		const fake = fakeSystem({ onSpawn: (command, args, child) => setImmediate(() => child.stdout.emit("data", Buffer.from(`Port: ${args[3]}\n`))) });
		const spawnSync = fake.system.spawnSync;
		fake.system.spawnSync = (command, args) => (args[0] === "--version" ? { status: 0, stdout: "Rojo 7.7.1\n", stderr: "" } : spawnSync(command, args));
		fake.system.watch = (directory) => {
			watched.push(directory);
			return { close: () => watched.push("closed") };
		};
		const io = capture();
		const running = runWorkflow(["dev", "--no-open", "--port", String(port), ...flags], { cwd: root, ...io }, fake.system);
		await new Promise((resolve) => setTimeout(resolve, 50));
		fake.interrupt();
		assert.equal(await running, ExitCode.ok, io.err);
		if (expected === undefined) {
			assert.deepEqual(watched, []);
			assert.doesNotMatch(io.out, /captures/);
		} else {
			assert.match(io.out, expected);
			assert.deepEqual(watched, [root, "closed"]);
		}
	}
});
