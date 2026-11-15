// Packs krf-tools and create-krf, installs the creator from its tarball in an isolated directory,
// creates a project through the installed bin, and runs the project's npm script against the
// packed tooling. No workspace links or repository paths are visible to the installed packages.
// Before krf-tools is on the registry, the project installs the packed tarball in its place.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const PACKAGES = fileURLToPath(new URL("../../../", import.meta.url));
const WINDOWS = process.platform === "win32";

function run(command, args, cwd) {
	const env = { ...process.env, npm_config_audit: "false", npm_config_fund: "false" };
	// Windows starts .cmd shims through a shell. Quote arguments, which may be paths with spaces, but
	// not the command: a quoted npm.cmd cannot locate its own installation.
	const result = WINDOWS
		? spawnSync([command, ...args.map((arg) => `"${arg}"`)].join(" "), { cwd, encoding: "utf8", shell: true, env })
		: spawnSync(command, args, { cwd, encoding: "utf8", env });
	assert.equal(result.status, 0, `${command} ${args.join(" ")} failed in ${cwd}\n${result.stdout}\n${result.stderr}`);
	return result.stdout;
}

function pack(packageDir, destination) {
	const output = JSON.parse(run("npm", ["pack", "--json", "--pack-destination", destination], packageDir));
	return { file: path.join(destination, output[0].filename), files: output[0].files.map((entry) => entry.path).sort() };
}

test("a packed create-krf creates a project whose npm script runs the packed tooling", { timeout: 300000 }, (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-pack-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const tarballs = path.join(root, "tarballs");
	fs.mkdirSync(tarballs);

	const tooling = pack(path.join(PACKAGES, "krf-tools"), tarballs);
	const creator = pack(path.join(PACKAGES, "create-krf"), tarballs);

	assert.ok(creator.files.includes("templates/base/_gitignore"), "npm must keep the gitignore template");
	assert.ok(creator.files.includes("templates/ci/.github/workflows/ci.yml"));
	assert.ok(!creator.files.some((file) => file.startsWith("tests/")), "tests must not ship");
	assert.ok(!tooling.files.some((file) => file.startsWith("tests/")), "tests must not ship");

	const installRoot = path.join(root, "creator");
	fs.mkdirSync(installRoot);
	run("npm", ["init", "--yes"], installRoot);
	run("npm", ["install", tooling.file, creator.file], installRoot);
	assert.equal(fs.lstatSync(path.join(installRoot, "node_modules", "krf-tools")).isSymbolicLink(), false);

	const work = path.join(root, "work");
	fs.mkdirSync(work);
	const bin = path.join(installRoot, "node_modules", ".bin", WINDOWS ? "create-krf.cmd" : "create-krf");
	const created = run(bin, ["my-game", "--yes", "--skip-install", "--no-git"], work);
	assert.match(created, /Created my-game/);

	const project = path.join(work, "my-game");
	assert.equal(fs.existsSync(path.join(project, ".gitignore")), true);
	const manifest = JSON.parse(fs.readFileSync(path.join(project, "package.json"), "utf8"));
	assert.deepEqual(manifest.devDependencies, { "krf-tools": JSON.parse(fs.readFileSync(path.join(PACKAGES, "krf-tools", "package.json"), "utf8")).version });

	run("npm", ["install", "--no-save", tooling.file], project);
	const info = run("npm", ["run", "--silent", "project:info", "--", "--json"], project);
	assert.equal(JSON.parse(info).project.name, "my-game");
	assert.deepEqual(JSON.parse(fs.readFileSync(path.join(project, "package.json"), "utf8")), manifest);
});
