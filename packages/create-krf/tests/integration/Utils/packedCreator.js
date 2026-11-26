import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PACKAGES = fileURLToPath(new URL("../../../../", import.meta.url));
export const WINDOWS = process.platform === "win32";

export function run(command, args, cwd, options = {}) {
	const env = { ...process.env, npm_config_audit: "false", npm_config_fund: "false", ...options.env };
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

export function packTarballs(destination) {
	fs.mkdirSync(destination, { recursive: true });
	return { tooling: pack(path.join(PACKAGES, "krf-tools"), destination), creator: pack(path.join(PACKAGES, "create-krf"), destination) };
}

export function tarballsIn(directory) {
	const find = (prefix) => {
		const matches = fs.readdirSync(directory).filter((file) => file.startsWith(prefix) && file.endsWith(".tgz"));
		assert.equal(matches.length, 1, `${directory} must hold exactly one ${prefix}*.tgz tarball, found ${JSON.stringify(matches)}`);
		return { file: path.resolve(directory, matches[0]) };
	};
	return { tooling: find("kevmp-krf-tools-"), creator: find("create-krf-") };
}

export function installPackedCreator(root, tarballs = packTarballs(path.join(root, "tarballs"))) {
	const { tooling, creator } = tarballs;
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
	const created = run(packed.bin, [name, "--yes", ...flags], work).stdout;
	assert.match(created, new RegExp(`Created ${name}`));

	return path.join(work, name);
}

export const GENERATED_DEFINITIONS = [
	["createTag", "--name", "Stunned"],
	["createTag", "--name", "Burning", "--duplicate-behavior", "Stack", "--max-stacks", "3", "--duration", "2", "--tick-interval", "0.5", "--property", "WalkSpeed:multiply=0.5,min=4"],
	["createResource", "--name", "Stamina"],
	["createResource", "--name", "Mana", "--max", "MaxMana", "--initial", "0", "--regen", "ManaRegen", "--visibility", "ClientVisible"],
	["createAction", "--name", "Fireball", "--requestable", "--auto-grant", "--blocked-tag", "Stunned", "--cost", "Stamina=10", "--hook", "onEnd"],
	[
		"createAction",
		"--name",
		"Guard",
		"--recipe",
		"held",
		"--requestable",
		"--auto-grant",
		"--applied-tag",
		"Burning:1",
		"--requirement",
		"Stamina:minPercent=0.1",
		"--lock",
		"Stance",
		"--interruptible-by",
		"Fireball",
		"--hook",
		"canBeInterruptedBy",
		"--start-field",
		"Element:Enum(Fire|Ice)",
		"--stop-field",
		"Direction:Array(F32,3)",
	],
	["createAction", "--name", "Ward", "--recipe", "toggle", "--requestable", "--auto-grant", "--stop-field", "Strength:U8"],
	["createAction", "--id", "Combat.Meditate", "--recipe", "channel", "--duration", "0.5", "--auto-grant", "--active-tag", "Burning:0.5"],
	["createController", "--name", "Cooldowns", "--depends-on", "ResourceController"],
	["createCommand", "--name", "CastSpell"],
	["createCommand", "--name", "Trade", "--target", "None", "--request-field", "Item:String(16)", "--result-field", "Accepted:Boolean", "--authorize", "AnyReadyClient"],
	["createHint", "--name", "ImpactFx", "--payload-field", "Position:Array(F32,3)"],
	["createHint", "--name", "Ping", "--direction", "ClientToServer"],
	["createDomain", "--name", "ComboState", "--state-field", "Count:U8", "--state-field", "Finished:Boolean", "--event", "Finisher(Damage:U16)"],
];

export function generateDefinitions(project) {
	fs.writeFileSync(path.join(project, "src/server/Properties/MaxMana.luau"), '--!strict\nreturn { id = "MaxMana", defaultBaseValue = 50 }\n');
	fs.writeFileSync(path.join(project, "src/server/Properties/ManaRegen.luau"), '--!strict\nreturn { id = "ManaRegen", defaultBaseValue = 1 }\n');
	for (const [script, ...args] of GENERATED_DEFINITIONS) {
		const result = JSON.parse(run("npm", ["run", "--silent", script, "--", ...args, "--yes", "--json"], project).stdout);
		assert.equal(result.status, "created", `${script} ${args.join(" ")}: ${JSON.stringify(result)}`);
	}
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
