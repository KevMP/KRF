import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { PACKAGES, createProject, installPackedCreator, run } from "../integration/Utils/packedCreator.js";

const FIXTURES = fileURLToPath(new URL("./", import.meta.url));
const REPOSITORY = path.resolve(PACKAGES, "..");
const TIMEOUT_SECONDS = Number(process.env.KRF_STARTER_TIMEOUT ?? 300);

const TEST_SECRET_TAG = `--!strict
return {
	id = "TestSecret",
	duplicateBehavior = "Ignore",
	visibility = "ServerOnly",
}
`;

function edit(project, file, from, to) {
	const full = path.join(project, file);
	const source = fs.readFileSync(full, "utf8");
	assert.ok(typeof from === "string" ? source.includes(from) : from.test(source), `${file} no longer contains ${from}`);
	fs.writeFileSync(full, source.replace(from, to));
}

const SCENARIOS = {
	starter: (project) => {
		fs.writeFileSync(path.join(project, "src", "server", "Tags", "TestSecret.luau"), TEST_SECRET_TAG);
	},
	"example-removed": (project) => {
		for (const file of ["server/Actions/Focus.luau", "server/Tags/Focused.luau", "server/Resources/Energy.luau"]) {
			fs.rmSync(path.join(project, "src", file));
		}
		for (const file of ["ActionInputPolicies.luau", "Controls", "EnergyDisplay.luau", "LocalCharacter.luau"]) {
			fs.rmSync(path.join(project, "src", "client", file), { recursive: true });
		}
		edit(project, "src/shared/ActionRequests.luau", /\tFocus = \{[\s\S]*?\n\t\},\n/, "");
		edit(
			project,
			"src/client/Startup.client.luau",
			"local ActionInputPolicies = require(script.Parent.ActionInputPolicies)\nlocal Controls = require(script.Parent.Controls)\nlocal EnergyDisplay = require(script.Parent.EnergyDisplay)\n",
			"",
		);
		edit(project, "src/client/Startup.client.luau", "\tactionInputPolicies = ActionInputPolicies,\n", "");
		edit(project, "src/client/Startup.client.luau", "\nControls.Start()\nEnergyDisplay.Start()\n", "");
	},
	"late-model": (project) => {
		edit(project, "src/client/Startup.client.luau", "\nControls.Start()\n", "\n");
	},
	"invalid-definitions": (project) => {
		edit(project, "src/server/Actions/Focus.luau", 'blockedTags = { "Focused" }', 'blockedTags = { "MissingTag" }');
	},
};

function studioPath() {
	if (process.env.KRF_STUDIO_PATH) return process.env.KRF_STUDIO_PATH;
	assert.equal(process.platform, "win32", "Set KRF_STUDIO_PATH to Roblox Studio on this platform");
	const resolved = spawnSync(
		"powershell",
		["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(REPOSITORY, "scripts", "fix-studio-path.ps1"), "-ResolveOnly"],
		{ encoding: "utf8" },
	);
	assert.equal(resolved.status, 0, `Could not resolve Roblox Studio: ${resolved.stderr}`);
	return resolved.stdout.trim();
}

function testProject(project, scenario) {
	const fixtures = path.join(project, "native-test");
	fs.mkdirSync(fixtures);
	for (const file of ["Server.server.luau", "Client.client.luau"]) fs.copyFileSync(path.join(FIXTURES, file), path.join(fixtures, file));

	const generated = JSON.parse(fs.readFileSync(path.join(project, "default.project.json"), "utf8"));
	const tree = structuredClone(generated.tree);
	tree.ReplicatedStorage.StarterTestControl = { $className: "RemoteEvent", $attributes: { Scenario: scenario } };
	tree.ServerScriptService.StarterTest = { $path: "native-test/Server.server.luau" };
	tree.StarterPlayer.StarterPlayerScripts.StarterTest = { $path: "native-test/Client.client.luau" };
	fs.writeFileSync(path.join(project, "native-test.project.json"), `${JSON.stringify({ name: generated.name, tree }, null, 2)}\n`);

	const place = path.join(project, "build", "native-test.rbxl");
	fs.mkdirSync(path.dirname(place), { recursive: true });
	run("rojo", ["build", "native-test.project.json", "--output", place], project);
	return place;
}

async function runStudio(studio, place, logs) {
	const output = path.join(logs, "result.log");
	const child = spawn(
		studio,
		["--task", "RunScript", "--localPlaceFile", place, "--runScriptFile", path.join(FIXTURES, "Launcher.luau"), "--outputFile", output, "--quitAfterExecution"],
		{ stdio: "ignore", windowsHide: true },
	);

	const exited = await new Promise((resolve) => {
		const timer = setTimeout(() => {
			child.kill();
			resolve(false);
		}, TIMEOUT_SECONDS * 1000);
		child.on("exit", () => {
			clearTimeout(timer);
			resolve(true);
		});
	});

	const text = fs.existsSync(output) ? fs.readFileSync(output, "utf8") : "";
	const marker = text.match(/^__KRF_STARTER_(PASS|FAIL)__ (\{[^\r\n]*\})\r?$/m);
	if (!exited) return { ok: false, detail: `Studio timed out after ${TIMEOUT_SECONDS}s` };
	if (!marker) return { ok: false, detail: "Studio produced no result marker" };
	const result = JSON.parse(marker[2]);
	return { ok: marker[1] === "PASS" && result.success === true, detail: JSON.stringify(result) };
}

async function main() {
	const requested = process.argv.slice(2);
	const scenarios = requested.length > 0 ? requested : Object.keys(SCENARIOS);
	for (const scenario of scenarios) assert.ok(SCENARIOS[scenario], `Unknown scenario ${scenario}`);

	const root = path.join(REPOSITORY, "build", "starter-native", randomUUID().slice(0, 8));
	fs.mkdirSync(root, { recursive: true });
	console.log(`Packing create-krf and krf-tools; logs: ${root}`);
	const packed = installPackedCreator(root);
	const studio = studioPath();

	const failures = [];
	for (const scenario of scenarios) {
		const project = createProject(packed, path.join(root, "work"), `starter-${scenario}`, ["--mode", "full", "--no-ci"]);
		SCENARIOS[scenario](project);
		run("npm", ["install"], project);
		run("npm", ["run", "build"], project);

		const place = testProject(project, scenario);
		console.log(`Running ${scenario} with one server and two clients...`);
		const result = await runStudio(studio, place, project);
		console.log(`${result.ok ? "PASS" : "FAIL"} ${scenario}: ${result.detail}`);
		if (!result.ok) failures.push(scenario);
	}

	if (failures.length > 0) {
		console.error(`Native starter scenarios failed: ${failures.join(", ")}. Logs: ${root}`);
		process.exitCode = 1;
	}
}

await main();
