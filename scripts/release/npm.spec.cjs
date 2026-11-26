const test = require("node:test");
const assert = require("node:assert/strict");

const { checkNpmVersion, checkReleaseVersions, classifyRegistryLookup, decidePublish } = require("./npm.cjs");

const INTEGRITY = "sha512-tested==";

const tooling = (version = "0.1.0") => ({ name: "@kevmp/krf-tools", version });
const creator = (pinned = "0.1.0", version = "0.1.0") => ({ name: "create-krf", version, dependencies: { "@kevmp/krf-tools": pinned, zod: "4.6.7" } });

test("checkReleaseVersions accepts release versions with an exact krf-tools pin", () => {
	assert.deepEqual(checkReleaseVersions({ tooling: tooling(), creator: creator() }), { ok: true });
	assert.deepEqual(checkReleaseVersions({ tooling: tooling("1.4.0"), creator: creator("1.4.0", "0.3.2") }), { ok: true });
});

test("checkReleaseVersions rejects a creator that doesn't pin the krf-tools being published", () => {
	for (const pinned of ["0.0.9", "^0.1.0", "~0.1.0", "file:../krf-tools"]) {
		const result = checkReleaseVersions({ tooling: tooling(), creator: creator(pinned) });
		assert.equal(result.ok, false, pinned);
		assert.match(result.reason, /must pin @kevmp\/krf-tools 0\.1\.0 exactly/);
	}

	const missing = checkReleaseVersions({ tooling: tooling(), creator: { name: "create-krf", version: "0.1.0" } });
	assert.match(missing.reason, /depends on nothing/);
});

test("checkReleaseVersions rejects prerelease and malformed versions", () => {
	for (const version of ["0.1.0-beta.1", "0.1", "v0.1.0", "01.0.0", "0.1.0+build"]) {
		assert.equal(checkReleaseVersions({ tooling: tooling(version), creator: creator(version) }).ok, false, version);
		assert.equal(checkReleaseVersions({ tooling: tooling(), creator: creator("0.1.0", version) }).ok, false, version);
	}
});

test("checkNpmVersion requires the npm that supports trusted publishing", () => {
	assert.deepEqual(checkNpmVersion("11.5.1"), { ok: true });
	assert.deepEqual(checkNpmVersion("11.19.0"), { ok: true });
	assert.deepEqual(checkNpmVersion("12.0.0"), { ok: true });
	for (const version of ["11.5.0", "10.9.2", "garbage"]) {
		assert.match(checkNpmVersion(version).reason, /needs npm 11\.5\.1 or later/, version);
	}
});

test("classifyRegistryLookup reads present, absent and unreadable versions", () => {
	assert.deepEqual(classifyRegistryLookup({ exitCode: 0, stdout: `"${INTEGRITY}"\n`, stderr: "" }), { state: "present", integrity: INTEGRITY });
	assert.deepEqual(classifyRegistryLookup({ exitCode: 0, stdout: "\n", stderr: "" }), { state: "absent" });
	assert.deepEqual(
		classifyRegistryLookup({ exitCode: 1, stdout: '{ "error": { "code": "E404" } }', stderr: "npm error code E404\nnpm error 404 Not Found" }),
		{ state: "absent" },
	);
	assert.deepEqual(classifyRegistryLookup({ exitCode: 1, stdout: "", stderr: "npm error code E404" }), { state: "absent" });

	const offline = classifyRegistryLookup({ exitCode: 1, stdout: "", stderr: "npm error code ETIMEDOUT\n" });
	assert.deepEqual(offline, { state: "unknown", detail: "npm error code ETIMEDOUT" });
	assert.equal(classifyRegistryLookup({ exitCode: 0, stdout: '"sha1-old"', stderr: "" }).state, "unknown");
});

test("decidePublish publishes new versions and never republishes", () => {
	assert.deepEqual(decidePublish("krf-tools@0.1.0", { state: "absent" }, INTEGRITY), { action: "publish" });
	assert.deepEqual(decidePublish("krf-tools@0.1.0", { state: "present", integrity: INTEGRITY }, INTEGRITY), { action: "skip" });

	const different = decidePublish("krf-tools@0.1.0", { state: "present", integrity: "sha512-other==" }, INTEGRITY);
	assert.equal(different.action, "stop");
	assert.match(different.reason, /already has krf-tools@0\.1\.0 with different contents/);

	const unknown = decidePublish("krf-tools@0.1.0", { state: "unknown", detail: "ETIMEDOUT" }, INTEGRITY);
	assert.deepEqual(unknown, { action: "stop", reason: "Could not read krf-tools@0.1.0 from npm: ETIMEDOUT" });
});
