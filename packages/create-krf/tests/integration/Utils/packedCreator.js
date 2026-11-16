import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PACKAGES = fileURLToPath(new URL("../../../../", import.meta.url));
export const WINDOWS = process.platform === "win32";

export function run(command, args, cwd, options = {}) {
	const env = { ...process.env, npm_config_audit: "false", npm_config_fund: "false" };
	const result = WINDOWS
		? spawnSync([command, ...args.map((arg) => `"${arg}"`)].join(" "), { cwd, encoding: "utf8", shell: true, env })
		: spawnSync(command, args, { cwd, encoding: "utf8", env });
	if (!options.allowFailure) {
		assert.equal(result.status, 0, `${command} ${args.join(" ")} failed in ${cwd}\n${result.stdout}\n${result.stderr}`);
	}
	return result;
}

function pack(packageDir, destination) {
	const output = JSON.parse(run("npm", ["pack", "--json", "--pack-destination", destination], packageDir).stdout);
	return { file: path.join(destination, output[0].filename), files: output[0].files.map((entry) => entry.path).sort() };
}

export function installPackedCreator(root) {
	const tarballs = path.join(root, "tarballs");
	fs.mkdirSync(tarballs, { recursive: true });
	const tooling = pack(path.join(PACKAGES, "krf-tools"), tarballs);
	const creator = pack(path.join(PACKAGES, "create-krf"), tarballs);

	const installRoot = path.join(root, "creator");
	fs.mkdirSync(installRoot);
	run("npm", ["init", "--yes"], installRoot);
	run("npm", ["install", tooling.file, creator.file], installRoot);

	return {
		tooling,
		creator,
		installRoot,
		bin: path.join(installRoot, "node_modules", ".bin", WINDOWS ? "create-krf.cmd" : "create-krf"),
	};
}

export function createProject(packed, work, name, flags) {
	fs.mkdirSync(work, { recursive: true });
	const created = run(packed.bin, [name, "--yes", "--no-git", ...flags], work).stdout;
	assert.match(created, new RegExp(`Created ${name}`));

	return path.join(work, name);
}

export function readTree(root) {
	const files = {};
	for (const entry of fs.readdirSync(root, { recursive: true, withFileTypes: true })) {
		if (!entry.isFile()) continue;
		const full = path.join(entry.parentPath, entry.name);
		files[path.relative(root, full).split(path.sep).join("/")] = fs.readFileSync(full, "utf8");
	}
	return files;
}
