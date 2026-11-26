import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

import { createProject, installPackedCreator, run } from "./Utils/packedCreator.js";

test("packed Full no-CI project builds locally and publishes to a mocked assigned Dev place", { timeout: 300000 }, (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-deploy-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const packed = installPackedCreator(root);
	const project = createProject(packed, root, "full-no-ci", ["--mode", "full", "--no-ci", "--no-git"]);
	assert.equal(fs.existsSync(path.join(project, ".github")), false);
	run("npm", ["install"], project);
	run("npm", ["run", "build"], project);

	const packageFile = path.join(project, "package.json");
	const manifest = JSON.parse(fs.readFileSync(packageFile, "utf8"));
	manifest.krf = { ...manifest.krf };
	manifest.krf.deployment = {
		owner: { kind: "group", id: "1101" },
		developers: { alex: { universeId: "2101", placeId: "3101" } },
		qa: { universeId: "2102", placeId: "3102" },
		production: { universeId: "2103", placeId: "3103" },
	};
	fs.writeFileSync(packageFile, JSON.stringify(manifest, null, 2) + "\n");
	run("git", ["init"], project);
	run("git", ["add", "."], project);
	run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Create Full test game"], project);

	const mock = new URL("./fixtures/disposable-open-cloud.mjs", import.meta.url);
	const isolatedTemp = path.join(root, "deploy-temp");
	fs.mkdirSync(isolatedTemp);
	const env = {
		NODE_OPTIONS: `--import=${pathToFileURL(path.join(project, "build", "mock-open-cloud.mjs")).href}`,
		TMP: isolatedTemp,
		TEMP: isolatedTemp,
		TMPDIR: isolatedTemp,
		KRF_ROBLOX_DEV_KEY: "dev-fixture",
		KRF_DEVELOPER: "alex",
	};
	fs.mkdirSync(path.join(project, "build"), { recursive: true });
	fs.copyFileSync(mock, path.join(project, "build", "mock-open-cloud.mjs"));
	const npm = (command, args = [], allowFailure = false, overrides = {}, cwd = project) => {
		const result = run("npm", ["run", "--silent", command, "--", ...args, "--json"], cwd, { env: { ...env, ...overrides }, allowFailure });
		return { statusCode: result.status, ...JSON.parse(result.stdout) };
	};
	assert.equal(npm("env:list").targets[0].credential, "present");
	assert.equal(npm("deploy:dev", ["--verify-target"]).keyScope, "verified-by-roblox");
	assert.equal(fs.existsSync(path.join(project, "build", "upload.sha")), false);
	const result = npm("deploy:dev");
	assert.equal(result.status, "confirmed-published");
	assert.equal(result.revisionId, "53");
	assert.equal(result.source.dirty, false);
	assert.equal(result.placeSha256, fs.readFileSync(path.join(project, "build", "upload.sha"), "utf8"));
	assert.equal(npm("deploy:qa", [], true).code, "missing-credential");
	assert.equal(npm("deploy:prod", [], true).code, "github-required");
	assert.equal(npm("release:tag", [], true).code, "github-required");

	const multiProject = createProject(packed, root, "multi-no-ci", ["--mode", "full", "--no-ci", "--places", "lobby,dungeon", "--no-git"]);
	const multiPackage = path.join(multiProject, "package.json");
	const multiManifest = JSON.parse(fs.readFileSync(multiPackage, "utf8"));
	assert.equal(multiManifest.krf.startPlace, "lobby");
	assert.equal(multiManifest.krf.placeProjects, undefined);
	assert.equal(fs.existsSync(path.join(multiProject, "default.project.json")), false);
	for (const name of ["lobby", "dungeon"]) assert.ok(fs.existsSync(path.join(multiProject, "places", `${name}.project.json`)));
	assert.ok(fs.existsSync(path.join(multiProject, "world", "lobby", "Workspace", "Baseplate.model.json")));
	assert.ok(fs.existsSync(path.join(multiProject, "world", "dungeon", "Workspace", "Baseplate.model.json")));
	fs.writeFileSync(path.join(multiProject, "world", "dungeon", "Workspace", "Dungeon.model.json"), '{"className":"Folder"}\n');
	run("npm", ["install"], multiProject);
	const map = JSON.parse(fs.readFileSync(path.join(multiProject, "sourcemap.json"), "utf8"));
	assert.equal(map.name, "multi-no-ci-lobby");
	run("npm", ["run", "typecheck"], multiProject);
	const local = npm("build", [], false, { KRF_ROBLOX_DEV_KEY: "" }, multiProject);
	assert.notEqual(local.places.lobby.placeSha256, local.places.dungeon.placeSha256);

	multiManifest.krf.deployment = {
		owner: manifest.krf.deployment.owner,
		developers: { alex: { universeId: "2101", places: { lobby: "3101", dungeon: "3104" } } },
	};
	fs.writeFileSync(multiPackage, JSON.stringify(multiManifest, null, 2) + "\n");
	run("git", ["init"], multiProject);
	run("git", ["add", "."], multiProject);
	run("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Create two-place test game"], multiProject);
	const multi = npm("deploy:dev", [], false, {}, multiProject);
	assert.equal(multi.status, "confirmed-published");
	assert.equal(multi.places.lobby.placeSha256, local.places.lobby.placeSha256);
	assert.equal(multi.places.dungeon.placeSha256, local.places.dungeon.placeSha256);
	assert.equal(fs.readFileSync(path.join(multiProject, "build", "multi-place-uploads.log"), "utf8"), "3104\n3101\n");

	const hybrid = createProject(packed, root, "hybrid-no-ci", ["--mode", "hybrid", "--no-ci", "--no-git"]);
	run("npm", ["install", "--ignore-scripts"], hybrid);
	const refused = run("npm", ["run", "--silent", "deploy:dev", "--", "--json"], hybrid, { env, allowFailure: true });
	assert.notEqual(refused.status, 0);
	assert.equal(JSON.parse(refused.stdout).code, "unsupported-project-mode");
});
