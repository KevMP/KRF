import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import { CREATOR_VERSION, KRF_RUNTIME, KRF_TOOLING } from "../src/compatibility.js";

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const toolingPackage = JSON.parse(fs.readFileSync(new URL("../../krf-tools/package.json", import.meta.url), "utf8"));
const creatorPackage = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));

test("pins exact creator, runtime and tooling versions", () => {
	assert.match(CREATOR_VERSION, SEMVER);
	assert.match(KRF_RUNTIME.version, SEMVER);
	assert.equal(KRF_RUNTIME.package, "kevmp/krf");
	assert.match(KRF_TOOLING.version, SEMVER);
});

test("generated projects pin the krf-tools version this creator is built with", () => {
	assert.equal(KRF_TOOLING.package, toolingPackage.name);
	assert.equal(KRF_TOOLING.version, toolingPackage.version);
});

test("publishes the executable, source and bundled templates", () => {
	assert.deepEqual(creatorPackage.bin, { "create-krf": "bin/create-krf.js" });
	for (const entry of ["bin", "src", "templates"]) assert.ok(creatorPackage.files.includes(entry), entry);
	for (const dependency of Object.values(creatorPackage.dependencies)) assert.match(dependency, SEMVER);
});
