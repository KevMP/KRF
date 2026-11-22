import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { runAssets } from "../src/assets/cli.js";
import { renderAssetModule, sha256 } from "../src/assets/manifest.js";
import { ExitCode } from "../src/errors.js";

const ANIMATION = "animation bytes";
const HASH = sha256(Buffer.from(ANIMATION));

function project(t, files = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-assets-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const all = {
		"package.json": JSON.stringify({ name: "my-game" }),
		"wally.toml": "[dependencies]\n",
		"assets/animations/Cast.rbxm": ANIMATION,
		...files,
	};
	for (const [file, contents] of Object.entries(all)) {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), typeof contents === "string" ? contents : `${JSON.stringify(contents, null, 2)}\n`);
	}
	return root;
}

async function check(root, argv = []) {
	const io = { out: "", err: "" };
	const code = await runAssets(["assets", "check", ...argv], { cwd: path.join(root, "assets"), stdout: (text) => (io.out += text), stderr: (text) => (io.err += text) });
	return { code, ...io };
}

const cast = (extra = {}) => ({ name: "FireballCast", kind: "Animation", id: 1234567890, source: "assets/animations/Cast.rbxm", sha256: HASH, ...extra });
const theme = { name: "Theme", kind: "Audio", id: 42, owner: { group: 7 } };
const MODULE = '--!strict\nreturn table.freeze({\n\tFireballCast = "rbxassetid://1234567890",\n\tTheme = "rbxassetid://42",\n})\n';

test("without a manifest there is nothing to check", async (t) => {
	const result = await check(project(t, { "src/shared/GameAssets.luau": "return {}\n" }));
	assert.equal(result.code, ExitCode.ok);
	assert.match(result.out, /No asset manifest at assets\/manifest\.json, so there is nothing to check/);
});

test("the generated module maps logical names to content IDs in name order", () => {
	assert.equal(renderAssetModule([theme, cast()]), MODULE);
	assert.equal(renderAssetModule([]), "--!strict\nreturn table.freeze({})\n");
});

test("a valid manifest passes locally and says remote access was not checked", async (t) => {
	const root = project(t, { "assets/manifest.json": { assets: [cast(), theme] }, "src/shared/GameAssets.luau": MODULE.replace(/\n/g, "\r\n") });
	const result = await check(root);
	assert.equal(result.code, ExitCode.ok, result.err);
	assert.match(result.out, /assets\/manifest\.json: 2 assets passed the local checks/);
	assert.match(result.out, /Not checked: whether these IDs exist on Roblox, or whether your account or group may use them/);
});

test("--write records missing hashes and regenerates the module, and never hides drift", async (t) => {
	const { sha256: _, ...unhashed } = cast();
	const root = project(t, { "assets/manifest.json": { assets: [unhashed, theme] } });

	const stale = await check(root);
	assert.equal(stale.code, ExitCode.failure);
	assert.match(stale.err, /needs updates:\n {2}FireballCast: sha256 of assets\/animations\/Cast\.rbxm is not recorded\n {2}src\/shared\/GameAssets\.luau does not exist\nRun npm run assets:check -- --write/);
	assert.equal(fs.existsSync(path.join(root, "src/shared/GameAssets.luau")), false);

	const written = await check(root, ["--write"]);
	assert.equal(written.code, ExitCode.ok, written.err);
	assert.match(written.out, /Updated assets\/manifest\.json and src\/shared\/GameAssets\.luau\./);
	const manifest = JSON.parse(fs.readFileSync(path.join(root, "assets/manifest.json"), "utf8"));
	assert.deepEqual(Object.keys(manifest.assets[0]), ["name", "kind", "id", "source", "sha256"]);
	assert.equal(manifest.assets[0].sha256, HASH);
	assert.equal(fs.readFileSync(path.join(root, "src/shared/GameAssets.luau"), "utf8"), MODULE);
	assert.equal((await check(root)).code, ExitCode.ok);

	fs.writeFileSync(path.join(root, "assets/animations/Cast.rbxm"), "re-exported animation");
	const drifted = await check(root, ["--write"]);
	assert.equal(drifted.code, ExitCode.failure);
	assert.match(drifted.err, /FireballCast: assets\/animations\/Cast\.rbxm changed since its sha256 was recorded\. Upload the new file to Roblox, set the new id/);
	assert.equal(JSON.parse(fs.readFileSync(path.join(root, "assets/manifest.json"), "utf8")).assets[0].sha256, HASH);
});

test("an edited module is out of date until it is regenerated", async (t) => {
	const root = project(t, { "assets/manifest.json": { assets: [cast(), theme] }, "src/shared/GameAssets.luau": MODULE.replace("42", "43") });
	const result = await check(root);
	assert.equal(result.code, ExitCode.failure);
	assert.match(result.err, /src\/shared\/GameAssets\.luau does not match the manifest/);
	assert.equal((await check(root, ["--write"])).code, ExitCode.ok);
	assert.equal(fs.readFileSync(path.join(root, "src/shared/GameAssets.luau"), "utf8"), MODULE);
});

test("invalid local records fail with every problem named", async (t) => {
	for (const [manifest, expected] of [
		["{ not json", [/assets\/manifest\.json is not valid JSON/]],
		[{ assets: {} }, [/assets: /]],
		[{ assets: [cast({ id: "rbxassetid://1234567890" })] }, [/FireballCast\.id: must be the numeric Roblox asset ID/]],
		[{ assets: [cast({ id: 12.5 })] }, [/FireballCast\.id: must be a whole number/]],
		[{ assets: [cast({ id: 0 })] }, [/FireballCast\.id: must be positive/]],
		[{ assets: [cast({ kind: "Sound" })] }, [/FireballCast\.kind: must be one of Animation, Audio, Image, Mesh/]],
		[{ assets: [cast({ sha256: "ABC" })] }, [/FireballCast\.sha256: must be 64 lowercase hexadecimal characters/]],
		[{ assets: [cast({ owner: { team: 1 } })] }, [/FireballCast\.owner: must be \{ "user": <id> \} or \{ "group": <id> \}/]],
		[{ assets: [cast({ url: "x" })] }, [/FireballCast: Unrecognized key/]],
		[{ assets: [cast(), cast({ name: "end" }), { ...theme, name: "Theme" }, { ...theme, name: "Theme" }] }, [/end: name must be a Luau identifier/, /Theme: the name is used by more than one asset/]],
		[{ assets: [cast({ source: "assets/animations/Missing.rbxm" })] }, [/FireballCast\.source: assets\/animations\/Missing\.rbxm does not exist/]],
		[{ assets: [cast({ source: "../Cast.rbxm" })] }, [/FireballCast\.source: must be a project-relative path/]],
		[{ assets: [cast({ source: "assets\\animations\\Cast.rbxm" })] }, [/FireballCast\.source: must be a project-relative path/]],
		[{ assets: [{ ...theme, sha256: HASH }] }, [/Theme: sha256 is set but there is no source file to hash/]],
	]) {
		const root = project(t, { "assets/manifest.json": manifest });
		const result = await check(root, ["--write"]);
		assert.equal(result.code, ExitCode.failure, JSON.stringify(manifest));
		for (const pattern of expected) assert.match(result.err, pattern);
		assert.equal(fs.existsSync(path.join(root, "src/shared/GameAssets.luau")), false, "nothing is written while records are invalid");
	}
});
