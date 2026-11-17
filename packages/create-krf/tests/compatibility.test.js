import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import { KRF_RUNTIME } from "krf-tools";

import { CREATOR_VERSION } from "../src/compatibility.js";

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const toolingPackage = JSON.parse(fs.readFileSync(new URL("../../krf-tools/package.json", import.meta.url), "utf8"));
const creatorPackage = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));

test("pins exact creator and runtime versions", () => {
	assert.match(CREATOR_VERSION, SEMVER);
	assert.match(KRF_RUNTIME.version, SEMVER);
	assert.equal(KRF_RUNTIME.package, "kevmp/krf");
});

test("depends on the krf-tools version in this repository", () => {
	assert.equal(creatorPackage.dependencies["krf-tools"], toolingPackage.version);
});

test("publishes the executable, source and bundled templates", () => {
	assert.deepEqual(creatorPackage.bin, { "create-krf": "bin/create-krf.js" });
	for (const entry of ["bin", "src", "templates"]) assert.ok(creatorPackage.files.includes(entry), entry);
	for (const dependency of Object.values(creatorPackage.dependencies)) assert.match(dependency, SEMVER);
});
