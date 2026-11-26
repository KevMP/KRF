import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { TOOLS_VERSION } from "@kevmp/krf-tools";

import { TOOLS_DEPENDENCY, toolsDependency } from "../src/tooling.js";

function install(t, lockfile, packages) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-tooling-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	fs.mkdirSync(path.join(root, "node_modules"), { recursive: true });
	fs.writeFileSync(path.join(root, lockfile), JSON.stringify({ packages }));
	return root;
}

const slash = (file) => file.split(path.sep).join("/");

test("a creator installed from a krf-tools tarball points new projects at that tarball", (t) => {
	const root = install(t, "node_modules/.package-lock.json", {
		"node_modules/@kevmp/krf-tools": { resolved: "file:../tarballs/kevmp-krf-tools-0.1.0.tgz" },
	});
	assert.equal(toolsDependency(path.join(root, "node_modules", "@kevmp", "krf-tools")), `file:${slash(path.resolve(root, "..", "tarballs", "kevmp-krf-tools-0.1.0.tgz"))}`);

	const nested = install(t, "package-lock.json", {
		"node_modules/create-krf/node_modules/@kevmp/krf-tools": { resolved: "file:C:/packs/kevmp-krf-tools-0.1.0.tgz" },
	});
	assert.equal(toolsDependency(path.join(nested, "node_modules", "create-krf", "node_modules", "@kevmp", "krf-tools")), `file:${slash(path.resolve(nested, "C:/packs/kevmp-krf-tools-0.1.0.tgz"))}`);
});

test("a creator installed from the registry or run from the repository pins the exact krf-tools version", (t) => {
	const registry = install(t, "node_modules/.package-lock.json", {
		"node_modules/@kevmp/krf-tools": { resolved: "https://registry.npmjs.org/@kevmp/krf-tools/-/krf-tools-0.1.0.tgz" },
	});
	assert.equal(toolsDependency(path.join(registry, "node_modules", "@kevmp", "krf-tools")), TOOLS_VERSION);

	const unlisted = install(t, "node_modules/.package-lock.json", {});
	assert.equal(toolsDependency(path.join(unlisted, "node_modules", "@kevmp", "krf-tools")), TOOLS_VERSION);

	assert.equal(toolsDependency(path.join(os.tmpdir(), "packages", "krf-tools")), TOOLS_VERSION);
	assert.deepEqual(TOOLS_DEPENDENCY, { "@kevmp/krf-tools": TOOLS_VERSION });
});
