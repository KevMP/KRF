import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KrfToolError, PROJECT_METADATA_FILE, readProjectMetadata, serializeProjectMetadata } from "../src/index.js";

const METADATA = {
	metadataVersion: 1,
	name: "my-game",
	options: { mode: "full", tooling: "standard", ci: true, agents: false },
	creator: { name: "create-krf", version: "0.1.0" },
	template: { version: "0.1.0" },
	runtime: { package: "kevmp/krf", version: "0.1.0" },
	tooling: { package: "krf-tools", version: "0.1.0" },
};

function projectWith(t, contents) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-project-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	if (contents !== undefined) fs.writeFileSync(path.join(root, PROJECT_METADATA_FILE), contents);
	return root;
}

test("serializes metadata with a stable key order regardless of input order", () => {
	const reordered = { tooling: METADATA.tooling, ...METADATA, options: { agents: false, ci: true, tooling: "standard", mode: "full" } };
	assert.equal(serializeProjectMetadata(reordered), serializeProjectMetadata(METADATA));
	assert.match(serializeProjectMetadata(METADATA), /^\{\n {2}"metadataVersion": 1,\n {2}"name": "my-game",/);
});

test("reads metadata written by serializeProjectMetadata", (t) => {
	assert.deepEqual(readProjectMetadata(projectWith(t, serializeProjectMetadata(METADATA))), METADATA);
});

test("reports missing metadata with a stable code and a hint", (t) => {
	assert.throws(() => readProjectMetadata(projectWith(t)), (error) => {
		assert.ok(error instanceof KrfToolError);
		assert.equal(error.code, "ProjectMetadataMissing");
		assert.match(error.hint, /project created by create-krf/);
		return true;
	});
});

test("rejects metadata that is not JSON", (t) => {
	assert.throws(() => readProjectMetadata(projectWith(t, "{ nope")), { code: "ProjectMetadataInvalid" });
});

test("lists every schema problem, including unknown fields and unsupported options", (t) => {
	const invalid = { ...METADATA, extra: true, options: { ...METADATA.options, mode: "studio" }, runtime: { package: "krf", version: "1" } };
	assert.throws(() => readProjectMetadata(projectWith(t, JSON.stringify(invalid))), (error) => {
		assert.equal(error.code, "ProjectMetadataInvalid");
		assert.match(error.message, /options\.mode/);
		assert.match(error.message, /runtime\.package/);
		assert.match(error.message, /runtime\.version: must be MAJOR\.MINOR\.PATCH/);
		assert.match(error.message, /extra/);
		return true;
	});
});
