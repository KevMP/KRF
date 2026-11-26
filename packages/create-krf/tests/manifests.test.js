import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KRF_RUNTIME } from "krf-tools";

import { ROKIT_VERSION, TOOLCHAIN } from "../src/compatibility.js";
import { buildProjectFiles } from "../src/create.js";
import { CAPTURED_SERVICES, wallyPackageName } from "../src/manifests.js";

const MATRIX = [];
for (const mode of ["full", "hybrid"])
	for (const ci of [true, false]) MATRIX.push({ mode, ci });

const config = (options, name = "my-game") => ({
	target: `/projects/${name}`,
	name,
	options: { mode: "full", ci: true, agents: false, ...options },
	git: false,
});

function files(options, name) {
	return new Map([...buildProjectFiles(config(options, name))].map(([file, contents]) => [file, contents.toString("utf8")]));
}

function mappedPaths(node, found = []) {
	for (const [key, value] of Object.entries(node)) {
		if (key === "$path") found.push(value);
		else if (!key.startsWith("$") && typeof value === "object") mappedPaths(value, found);
	}
	return found;
}

const CODE_TREES = ["ReplicatedStorage/Packages", "ReplicatedStorage/Shared", "ServerScriptService/Game", "StarterPlayer/StarterPlayerScripts/Game"];

function starterWorldFiles(generated) {
	return Object.fromEntries(
		["Baseplate", "SpawnLocation"].map((name) => {
			const model = JSON.parse(generated.get(`world/Workspace/${name}.model.json`));
			return [name, { $className: model.className, $properties: model.properties }];
		}),
	);
}

test("Full maps code and packages, and captures the starter world from world/Workspace", () => {
	const generated = files({ mode: "full" });
	const project = JSON.parse(generated.get("default.project.json"));
	assert.equal(project.name, "my-game");
	assert.equal(project.tree.$className, "DataModel");
	assert.equal(project.tree.ReplicatedStorage.Packages.$path, "Packages");
	assert.equal(project.tree.ReplicatedStorage.Shared.$path, "src/shared");
	assert.equal(project.tree.ServerScriptService.Game.$path, "src/server");
	assert.equal(project.tree.StarterPlayer.StarterPlayerScripts.Game.$path, "src/client");
	assert.deepEqual(project.tree.Workspace, { $className: "Workspace", $ignoreUnknownInstances: true, $path: "world/Workspace" });
	for (const service of CAPTURED_SERVICES) {
		const node = service.split("/").reduce((current, name) => current[name], project.tree);
		assert.equal(node.$path, `world/${service}`, service);
		assert.ok(generated.has(`world/${service}/.gitkeep`), `Git keeps world/${service} while it is empty`);
	}
	assert.deepEqual(Object.keys(project.tree.ReplicatedStorage), ["$className", "$ignoreUnknownInstances", "$path", "Packages", "Shared"]);
	assert.equal(project.tree.StarterPlayer.$path, undefined, "StarterPlayer settings live in the project file");
	assert.deepEqual(Object.keys(starterWorldFiles(generated)), ["Baseplate", "SpawnLocation"]);
	assert.equal(generated.get("world/Workspace/.gitkeep"), "", "Git keeps world/Workspace when every starter part is removed");
	assert.equal(generated.has("start-place.project.json"), false);
});

test("the named Full template generates an independent starter world and Rojo input for every place", () => {
	const generated = files({ places: ["lobby", "dungeon", "arena"] });
	const { krf, scripts } = JSON.parse(generated.get("package.json"));
	assert.equal(krf.startPlace, "lobby");
	assert.equal(krf.placeProjects, undefined);
	assert.equal(generated.has("default.project.json"), false);
	const editor = JSON.parse(generated.get(".vscode/settings.json"));
	assert.equal(editor["luau-lsp.sourcemap.generatorCommand"], "npm run --silent sourcemap");
	assert.equal(editor["luau-lsp.sourcemap.useVSCodeWatcher"], true);
	assert.equal(scripts.sourcemap, "krf-tools sourcemap");
	assert.equal(scripts.build, "krf-tools build:places");
	assert.match(scripts.typecheck, /^krf-tools sourcemap && /);
	assert.ok(![...generated.keys()].some((file) => file.startsWith("world/Workspace/")));
	for (const name of ["lobby", "dungeon", "arena"]) {
		const rojo = JSON.parse(generated.get(`places/${name}.project.json`));
		assert.equal(rojo.tree.ReplicatedStorage.Packages.$path, "../Packages");
		assert.equal(rojo.tree.ServerScriptService.Game.$path, "../src/server");
		for (const service of CAPTURED_SERVICES) {
			const node = service.split("/").reduce((current, segment) => current[segment], rojo.tree);
			assert.equal(node.$path, `../world/${name}/${service}`);
			assert.ok(generated.has(`world/${name}/${service}/.gitkeep`));
		}
		for (const model of ["Baseplate", "SpawnLocation"]) assert.ok(generated.has(`world/${name}/Workspace/${model}.model.json`));
	}
	assert.match(generated.get(".github/workflows/ci.yml"), /run: npm run build$/m);
	for (const workflow of ["deploy.yml", "release-pr.yml", "release.yml"]) assert.ok(generated.has(`.github/workflows/${workflow}`));
});

test("Hybrid live sync owns only code and packages; its start place adds the same starter world", () => {
	const generated = files({ mode: "hybrid" });
	const live = JSON.parse(generated.get("default.project.json"));
	const start = JSON.parse(generated.get("start-place.project.json"));

	assert.deepEqual(Object.keys(live.tree).sort(), ["$className", "ReplicatedStorage", "ServerScriptService", "StarterPlayer"]);
	assert.equal(live.tree.Workspace, undefined);
	assert.deepEqual(mappedPaths(live.tree).sort(), ["Packages", "src/client", "src/server", "src/shared"]);
	assert.ok(![...generated.keys()].some((file) => file.startsWith("world/")), "Hybrid projects own no world folder until one is opted in");

	const { Workspace, ...startCode } = start.tree;
	assert.deepEqual(startCode, live.tree);
	assert.equal(start.syncbackRules, undefined);
	const { $className, ...world } = Workspace;
	assert.equal($className, "Workspace");
	assert.deepEqual(world, starterWorldFiles(files({ mode: "full" })));
});

test("Rojo projects map only game source, installed packages and the captured world", () => {
	for (const options of MATRIX) {
		const generated = files(options);
		for (const file of [...generated.keys()].filter((name) => name.endsWith(".project.json"))) {
			const project = JSON.parse(generated.get(file));
			const world = options.mode === "full" && file === "default.project.json" ? CAPTURED_SERVICES.map((service) => `world/${service}`) : [];
			const allowed = ["Packages", "src/server", "src/client", "src/shared", ...world];
			for (const mapped of mappedPaths(project.tree)) {
				assert.ok(allowed.includes(mapped), `${file} maps ${mapped}`);
				if (mapped !== "Packages") assert.ok([...generated.keys()].some((name) => name.startsWith(`${mapped}/`)), mapped);
			}
			for (const service of CAPTURED_SERVICES) {
				const node = service.split("/").reduce((current, name) => current?.[name], project.tree);
				if (node === undefined) continue;
				assert.equal(node.$ignoreUnknownInstances, node.$path === undefined ? undefined : true, `${file} ${service}: live sync must keep Studio-made content`);
			}
		}
	}
});

test("syncback never captures code, packages, terrain or Studio properties Rojo cannot recognize", () => {
	for (const options of MATRIX) {
		const project = JSON.parse(files(options).get("default.project.json"));
		assert.deepEqual(project.syncbackRules.ignoreTrees, [...CODE_TREES, "Workspace/Terrain"], options.mode);
		assert.deepEqual(project.syncbackRules.ignoreProperties.Instance, ["ExplorerIconContent", "SerializedOverrides"], "properties newer Studio builds save but Rojo 7.7.1 does not know");
	}
});

test("the starter world is placed with CFrame, which Studio loads, not Position, which it drops", () => {
	for (const options of MATRIX) {
		for (const [file, contents] of files(options)) {
			if (file.endsWith(".json")) assert.doesNotMatch(contents, /"Position"/, file);
		}
	}
	const { Baseplate, SpawnLocation } = starterWorldFiles(files({}));
	assert.deepEqual(Baseplate.$properties.CFrame, [0, -8, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
	assert.deepEqual(SpawnLocation.$properties.CFrame, [0, 0.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
});

test("rokit.toml pins the toolchain KRF is built with", () => {
	const repositoryTools = Object.fromEntries(
		[...fs.readFileSync(new URL("../../../rokit.toml", import.meta.url), "utf8").matchAll(/^\s*[\w-]+\s*=\s*"([^"@]+)@([^"]+)"/gm)].map((match) => [
			match[1].toLowerCase(),
			match[2],
		]),
	);

	const rokit = files({}).get("rokit.toml");
	for (const [alias, tool] of Object.entries(TOOLCHAIN)) {
		const [name, version] = tool.split("@");
		assert.equal(repositoryTools[name.toLowerCase()], version, tool);
		assert.match(rokit, new RegExp(`^${alias} = "${tool}"$`, "m"));
	}
});

test("npm install runs a valid setup script that installs the pinned Rokit release for every platform", () => {
	const generated = files({});
	assert.equal(JSON.parse(generated.get("package.json")).scripts.postinstall, "node scripts/setup.mjs");

	const setup = generated.get("scripts/setup.mjs");
	assert.match(setup, new RegExp(`^const ROKIT_VERSION = "${ROKIT_VERSION}";$`, "m"));
	assert.match(setup, /https:\/\/github\.com\/rojo-rbx\/rokit\/releases\/download\/v\$\{ROKIT_VERSION\}\/rokit-\$\{ROKIT_VERSION\}-\$\{target\}\.zip/);
	const targets = [...setup.matchAll(/^\t"[\w-]+": "([\w-]+)",$/gm)].map((match) => match[1]).sort();
	assert.deepEqual(targets, ["linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64", "windows-aarch64", "windows-x86_64"]);
	assert.match(setup, /run\("rojo", \["sourcemap", "default\.project\.json", "--output", "sourcemap\.json"\]\)/);

	const directory = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-setup-"));
	try {
		const script = path.join(directory, "setup.mjs");
		fs.writeFileSync(script, setup);
		const checked = spawnSync(process.execPath, ["--check", script], { encoding: "utf8" });
		assert.equal(checked.status, 0, checked.stderr);
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
});

test("wally.toml depends on exactly the KRF release the templates target", () => {
	const manifest = files({}).get("wally.toml");
	assert.match(manifest, /^name = "my-game\/my-game"$/m);
	assert.match(manifest, /^private = true$/m);
	assert.match(manifest, new RegExp(`^KRF = "${KRF_RUNTIME.package}@=${KRF_RUNTIME.version}"$`, "m"));
});

test("check never changes files, format is the only formatter, and CI runs check", () => {
	const generated = files({});
	const { check, format } = JSON.parse(generated.get("package.json")).scripts;
	assert.equal(check, "stylua --check src tests && selene src tests && npm run typecheck");
	assert.equal(format, "stylua src tests");
	const workflow = generated.get(".github/workflows/ci.yml");
	assert.match(workflow, /^ {8}run: npm run check$/m);
	assert.doesNotMatch(workflow, /npm run format/);
});

test("Full builds the place at the root; Hybrid builds into build/ and never touches the Studio-owned place", () => {
	assert.equal(JSON.parse(files({}).get("package.json")).scripts.build, "rojo build default.project.json --output my-game.rbxl");
	assert.equal(JSON.parse(files({ mode: "hybrid" }).get("package.json")).scripts.build, `node -e "require('node:fs').mkdirSync('build', { recursive: true })" && rojo build start-place.project.json --output build/my-game.rbxl`);
});

test("Jest is a Wally dev dependency and the starter ships a Jest config and spec", () => {
	const generated = files({});
	assert.match(generated.get("wally.toml"), /^\[dev-dependencies\]\nJest = "jsdotlua\/jest@3\.10\.0"\nJestGlobals = "jsdotlua\/jest-globals@3\.10\.0"$/m);
	assert.match(generated.get("tests/jest.config.luau"), /testMatch = \{ "\*\*\/\*\.spec" \}/);
	assert.match(generated.get("tests/Definitions.spec.luau"), /require\(ReplicatedStorage\.DevPackages\.JestGlobals\)/);
	assert.match(generated.get(".gitignore"), /^DevPackages\/$/m);
});

test("Wally package names use only characters Wally accepts", () => {
	assert.equal(wallyPackageName("my-game"), "my-game/my-game");
	assert.equal(wallyPackageName("my_game.v2"), "my-game-v2/my-game-v2");
});

test("only the server and client startup files are executable scripts", () => {
	const generated = [...files({}).keys()];
	assert.deepEqual(
		generated.filter((file) => /\.(server|client)\.luau$/.test(file)),
		["src/client/Startup.client.luau", "src/server/Startup.server.luau"],
	);
	assert.ok(generated.filter((file) => file.endsWith(".luau")).every((file) => /^(src\/(server|client|shared)|tests)\//.test(file)));
});

const ROOTS = { server: "ServerScriptService/Game", client: "StarterPlayerScripts/Game", shared: "ReplicatedStorage/Shared" };

function instancePath(file) {
	const [, root, rest] = file.match(/^src\/(server|client|shared)\/(.+)$/);
	const segments = [...ROOTS[root].split("/"), ...rest.split("/")];
	const leaf = segments.pop().replace(/(\.(server|client))?\.luau$/, "");
	return leaf === "init" ? segments : [...segments, leaf];
}

function resolve(file, expression) {
	const shared = expression.match(/^ReplicatedStorage(?:\.Shared\.|:WaitForChild\("Shared"\):WaitForChild\(")(\w+)"?\)?$/);
	if (shared) return ["ReplicatedStorage", "Shared", shared[1]];
	if (!expression.startsWith("script.")) return undefined;

	const target = [...instancePath(file)];
	for (const part of expression.split(".").slice(1)) {
		if (part === "Parent") target.pop();
		else target.push(part);
	}
	return target;
}

const PACKAGE_REQUIRES = new Set(["ReplicatedStorage.Packages.KRF", 'packages:WaitForChild("KRF")']);

test("every static require names KRF or a generated module, with exact case", () => {
	const generated = [...files({}).entries()].filter(([file]) => file.startsWith("src/") && file.endsWith(".luau"));
	const modules = new Set(generated.map(([file]) => instancePath(file).join("/")));
	let checked = 0;

	for (const [file, source] of generated) {
		for (const [, expression] of source.matchAll(/= require\((.+?)\)$/gm)) {
			checked += 1;
			if (PACKAGE_REQUIRES.has(expression)) continue;
			const target = resolve(file, expression);
			assert.ok(target !== undefined && modules.has(target.join("/")), `${file}: ${expression} -> ${target?.join("/")}`);
		}
	}

	assert.ok(checked >= 8, `only ${checked} requires were checked`);
});

test("every definition folder loads its descendants and startup passes it to Server.Init", () => {
	const generated = files({});
	const startup = generated.get("src/server/Startup.server.luau");
	const folders = [...new Set([...generated.keys()].map((file) => file.match(/^src\/server\/(\w+)\//)?.[1]).filter(Boolean))].sort();
	assert.deepEqual(folders, ["Actions", "Properties", "Resources", "Tags"]);

	for (const folder of folders) {
		assert.match(generated.get(`src/server/${folder}/init.luau`), /= requireDescendants\(script\)$/m, folder);
		assert.match(startup, new RegExp(`^local ${folder} = require\\(script\\.Parent\\.${folder}\\)$`, "m"), folder);
		assert.match(startup, new RegExp(`^\\t${folder.toLowerCase()} = ${folder},$`, "m"), folder);
	}

	for (const folder of ["src/shared/ActionRequests", "src/client/ActionInputPolicies"]) {
		assert.match(generated.get(`${folder}/init.luau`), /= mergeDescendants\(script\)$/m, folder);
	}
});

test("every loadout slot is a bound input and every equipped Action is registered and client-requestable", () => {
	const generated = files({});
	const actionIds = [...generated]
		.filter(([file]) => file.startsWith("src/server/Actions/"))
		.flatMap(([, source]) => [...source.matchAll(/^\s*id = "([^"]+)"/gm)].map((match) => match[1]));
	const requestable = [...generated]
		.filter(([file]) => file.startsWith("src/shared/ActionRequests/") && !file.endsWith("/init.luau"))
		.flatMap(([, source]) => [...source.matchAll(/^\t\[?"?([\w.]+)"?\]? = \{/gm)].map((match) => match[1]));
	const loadout = generated.get("src/client/Controls/Loadout.luau");
	const slots = [...loadout.match(/^local SLOTS: \{ string \} = \{ (.+) \}$/m)[1].matchAll(/"(\w+)"/g)].map((match) => match[1]);
	const equipped = Object.fromEntries([...loadout.match(/^local equipped[^\n]*\n([\s\S]*?)^\}$/m)[1].matchAll(/^\t(\w+) = "([^"]+)",$/gm)].map((match) => [match[1], match[2]]));
	const keybinds = generated.get("src/client/Controls/Keybinds.luau");

	assert.deepEqual(slots, ["AbilitySlot1"]);
	assert.deepEqual(equipped, { AbilitySlot1: "Focus" });
	for (const slot of slots) assert.match(keybinds, new RegExp(`^\\t+${slot} = \\{$`, "m"), `${slot} has no keybind`);
	for (const actionId of Object.values(equipped)) {
		assert.ok(actionIds.includes(actionId), `${actionId} is not a registered Action`);
		assert.ok(requestable.includes(actionId), `${actionId} is not in ActionRequests`);
	}
});

test("client code never requires server modules", () => {
	for (const [file, source] of files({})) {
		if (!file.startsWith("src/client/") && !file.startsWith("src/shared/")) continue;
		assert.doesNotMatch(source, /ServerScriptService|KRF\.Server\b|ActorRuntime/, file);
	}
});

test("the game source is identical in every option combination", () => {
	const source = (options) => [...files(options)].filter(([file]) => file.startsWith("src/"));
	const expected = source({});
	for (const options of MATRIX) assert.deepEqual(source(options), expected, JSON.stringify(options));
});
