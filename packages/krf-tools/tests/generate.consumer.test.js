import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KRF_RUNTIME } from "../src/compatibility.js";
import { assertPathAvailable, createConsumer, findDefinition, findProjectRoot, readKrfDependency } from "../src/generate/consumer.js";

const LOCK = (version) => `[[package]]\nname = "my-game/my-game"\nversion = "0.0.0"\n\n[[package]]\nname = "kevmp/krf"\nversion = "${version}"\ndependencies = []\n`;

function project(t, files) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-consumer-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	for (const [relative, contents] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
		if (contents !== null) fs.writeFileSync(path.join(root, relative), contents);
	}
	return root;
}

const dependency = (t, files) => readKrfDependency(createConsumer(project(t, files)));

test("reads the installed KRF version from wally.lock, or an exact wally.toml pin before install", (t) => {
	assert.deepEqual(dependency(t, { "wally.toml": `[dependencies]\nKRF = "kevmp/krf@=${KRF_RUNTIME.version}"\n` }), { alias: "KRF", version: KRF_RUNTIME.version });
	assert.deepEqual(dependency(t, { "wally.toml": '[dependencies]\nFramework = "kevmp/krf@0.2"\n', "wally.lock": LOCK(KRF_RUNTIME.version) }), {
		alias: "Framework",
		version: KRF_RUNTIME.version,
	});
});

test("refuses projects whose KRF version the generator cannot vouch for", (t) => {
	assert.throws(() => dependency(t, { "wally.toml": "[dependencies]\n" }), { code: "KrfDependencyMissing" });
	assert.throws(() => dependency(t, { "wally.toml": '[dependencies]\nKRF = "kevmp/krf@0.1"\n' }), { code: "KrfVersionUnresolved", hint: /npm install/ });
	assert.throws(() => dependency(t, { "wally.toml": '[dependencies]\nKRF = "kevmp/krf@=0.3.0"\n' }), { code: "KrfVersionUnsupported", message: /this project uses 0\.3\.0/ });
	assert.throws(() => dependency(t, { "wally.toml": '[dependencies]\nKRF = "kevmp/krf@=0.1.0"\n', "wally.lock": LOCK("0.3.1") }), { code: "KrfVersionUnsupported", hint: /npm install --save-dev --save-exact @kevmp\/krf-tools@/ });
	assert.throws(() => dependency(t, { "wally.toml": '[dependencies]\n"K-R-F" = "kevmp/krf@=0.1.0"\n' }), { code: "KrfAliasUnsupported" });
});

test("finds the project root from a nested directory and refuses non-KRF packages", (t) => {
	const root = project(t, { "package.json": "{}", "wally.toml": "", "src/server/Actions/x": null });
	assert.equal(findProjectRoot(path.join(root, "src", "server", "Actions")), root);

	const plain = project(t, { "package.json": "{}", "src/x": null });
	assert.throws(() => findProjectRoot(path.join(plain, "src")), { code: "NotKrfProject" });
});

test("refuses a path whose Rojo instance name another file or folder already uses, in any case", (t) => {
	const consumer = createConsumer(
		project(t, {
			"src/server/Actions/Fireball.lua": "",
			"src/server/Actions/Frost/init.luau": "",
			"src/server/Actions/combat/Slash.luau": "",
			"src/server/Actions/Dash.model.json": "{}",
			"src/server/Actions/Blink.meta.json": "{}",
			"src/server/Actions/Existing.luau": "",
		}),
	);

	for (const target of ["src/server/Actions/Fireball.luau", "src/server/Actions/frost.luau", "src/server/Actions/Combat/Slash.luau", "src/server/Actions/Dash.luau", "src/server/Actions/existing.luau", "src/server/actions/Nova.luau"]) {
		assert.throws(() => assertPathAvailable(consumer, target), { code: "NameConflict" }, target);
	}
	for (const target of ["src/server/Actions/Blink.luau", "src/server/Actions/combat/Cleave.luau", "src/server/Actions/Existing.luau", "src/server/Controllers/Cooldowns.luau"]) {
		assert.doesNotThrow(() => assertPathAvailable(consumer, target), target);
	}
});

test("finds an existing definition by its own id or key, not by ids it references", (t) => {
	const consumer = createConsumer(
		project(t, {
			"src/server/Actions/Focus.luau": 'function Focus()\n\treturn {\n\t\tid = "Focus",\n\t\tactiveTags = { { id = "Stunned" } },\n\t}\nend\n',
			"src/server/Actions/Nested/Dash.luau": 'return {\n\tid = "Combat.Dash",\n}\n',
			"src/server/Controllers/Threat.luau": 'return {\n\tkey = "Threat",\n}\n',
		}),
	);
	assert.equal(findDefinition(consumer, ["src/server/Actions"], "Focus"), "src/server/Actions/Focus.luau");
	assert.equal(findDefinition(consumer, ["src/server/Actions"], "Combat.Dash"), "src/server/Actions/Nested/Dash.luau");
	assert.equal(findDefinition(consumer, ["src/server/Controllers"], "Threat"), "src/server/Controllers/Threat.luau");
	assert.equal(findDefinition(consumer, ["src/server/Actions"], "Stunned"), undefined);
	assert.equal(findDefinition(consumer, ["src/server/Missing"], "Focus"), undefined);
});
