const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { parseReleaseTag, readPackageManifest, checkTagMatchesManifest, compareVersions, decideRelease } = require("./manifest.cjs");
const { nextVersion, applyVersionBump, releasePullRequest } = require("./bump.cjs");
const { validatePackageListing, checkArchiveSize, hashTree, compareTrees, MAX_ARCHIVE_BYTES } = require("./archive.cjs");
const { createRegistry } = require("./registry.cjs");
const { classifyPublishResult, describeRejection } = require("./publish.cjs");
const { deriveReleaseStatus, renderReleaseStatus, STATES } = require("./status.cjs");

const MANIFEST = `[package]
name = "kevmp/krf"
version = "0.1.0"
license = "MIT"

[dev-dependencies]
Jest = "jsdotlua/jest@3.10.0"
`;

function response(status, body = "") {
	return {
		status,
		ok: status >= 200 && status < 300,
		text: async () => body,
		arrayBuffer: async () => Buffer.from(body),
	};
}

function stubFetch(responses) {
	const calls = [];
	const fetch = async (url) => {
		calls.push(url);
		const next = responses.shift();
		if (next instanceof Error) throw next;
		return next;
	};
	return { fetch, calls };
}

const indexLine = (version) => JSON.stringify({ package: { name: "kevmp/krf", version } });

test("accepts only stable vMAJOR.MINOR.PATCH release tags", () => {
	assert.deepEqual(parseReleaseTag("v0.1.0"), { ok: true, version: "0.1.0" });
	assert.deepEqual(parseReleaseTag("v12.0.3"), { ok: true, version: "12.0.3" });
	for (const tag of ["0.1.0", "v0.1", "v01.0.0", "v0.1.0-rc.1", "v0.1.0+build", "release-0.1.0", undefined]) {
		assert.equal(parseReleaseTag(tag).ok, false, String(tag));
	}
});

test("reads package identity from the [package] table and ignores dependency tables", () => {
	assert.deepEqual(readPackageManifest(MANIFEST), { name: "kevmp/krf", version: "0.1.0", private: false });
	assert.equal(readPackageManifest(`${MANIFEST.replace("[dev", 'private = true\n[dev')}`).private, true);
	assert.throws(() => readPackageManifest('[package]\nversion = "0.1.0"\n'), /name/);
	assert.throws(() => readPackageManifest('[package]\nname = "kevmp/krf"\nversion = "1.0"\n'), /version/);
	assert.throws(() => readPackageManifest('[dependencies]\nname = "kevmp/krf"\nversion = "0.1.0"\n'), /name/);
});

test("requires the tag to name the manifest version at the tagged commit", () => {
	const manifest = readPackageManifest(MANIFEST);
	assert.deepEqual(checkTagMatchesManifest("v0.1.0", manifest), { ok: true, version: "0.1.0" });
	assert.match(checkTagMatchesManifest("v0.2.0", manifest).reason, /does not match wally.toml version 0.1.0/);
	assert.match(checkTagMatchesManifest("v0.1.0-rc.1", manifest).reason, /vMAJOR.MINOR.PATCH/);
	assert.match(checkTagMatchesManifest("v0.1.0", { ...manifest, private: true }).reason, /private/);
});

test("orders versions numerically rather than lexically", () => {
	assert.deepEqual(["0.10.0", "0.2.0", "1.0.0", "0.2.1"].sort(compareVersions), ["0.2.0", "0.2.1", "0.10.0", "1.0.0"]);
});

test("releases an untagged main version, resumes its own tag and skips a version tagged elsewhere", () => {
	assert.deepEqual(decideRelease({ version: "0.2.0", commit: "b", taggedCommit: null }), {
		release: true,
		tag: "v0.2.0",
		createTag: true,
	});
	assert.deepEqual(decideRelease({ version: "0.2.0", commit: "b", taggedCommit: "b" }), {
		release: true,
		tag: "v0.2.0",
		createTag: false,
	});

	const skipped = decideRelease({ version: "0.2.0", commit: "c", taggedCommit: "b" });
	assert.equal(skipped.release, false);
	assert.match(skipped.reason, /already tagged on b/);
});

test("chooses the next version from a bump level or a newer explicit version", () => {
	assert.deepEqual(nextVersion("0.9.3", "patch"), { ok: true, version: "0.9.4" });
	assert.deepEqual(nextVersion("0.9.3", "minor"), { ok: true, version: "0.10.0" });
	assert.deepEqual(nextVersion("0.9.3", "major"), { ok: true, version: "1.0.0" });
	assert.deepEqual(nextVersion("0.9.3", "0.12.0"), { ok: true, version: "0.12.0" });

	assert.match(nextVersion("0.9.3", "0.9.3").reason, /not newer/);
	assert.match(nextVersion("0.9.3", "0.8.0").reason, /not newer/);
	for (const target of ["1.0", "v1.0.0", "1.0.0-rc.1", "huge", ""]) {
		assert.match(nextVersion("0.9.3", target).reason, /major, minor, patch/, target);
	}
});

const LOCKFILE = `[[package]]
name = "jsdotlua/jest"
version = "0.1.0"
dependencies = []

[[package]]
name = "kevmp/krf"
version = "0.1.0"
dependencies = [["Jest", "jsdotlua/jest@0.1.0"]]
`;

test("bumps the package version in the manifest, lockfile and install snippets only", () => {
	const manifest = `${MANIFEST}Other = "someone/else@0.1.0"\n`;
	const bumped = applyVersionBump(
		{
			manifest,
			lockfile: LOCKFILE,
			installDocs: { "README.md": 'KRF = "kevmp/krf@0.1.0"\nOther = "kevmp/krf-extras@0.1.0"\n' },
		},
		{ name: "kevmp/krf", from: "0.1.0", to: "0.2.0" },
	);

	assert.equal(bumped.ok, true);
	assert.equal(bumped.manifest, manifest.replace('version = "0.1.0"', 'version = "0.2.0"'));
	assert.equal(readPackageManifest(bumped.manifest).version, "0.2.0");
	assert.match(bumped.manifest, /jsdotlua\/jest@3\.10\.0/);
	assert.match(bumped.manifest, /someone\/else@0\.1\.0/);
	assert.equal(bumped.lockfile, LOCKFILE.replace('krf"\nversion = "0.1.0"', 'krf"\nversion = "0.2.0"'));
	assert.equal(bumped.installDocs["README.md"], 'KRF = "kevmp/krf@0.2.0"\nOther = "kevmp/krf-extras@0.1.0"\n');
});

test("names the release branch and pull request after the new version", () => {
	const pullRequest = releasePullRequest({ name: "kevmp/krf", from: "0.1.0", to: "0.2.0" });

	assert.equal(pullRequest.branch, "release/v0.2.0");
	assert.equal(pullRequest.title, "chore(release): v0.2.0");
	assert.equal(pullRequest.body, "Bumps `kevmp/krf` from 0.1.0 to 0.2.0; merging publishes v0.2.0 to Wally.");
});

test("refuses a bump when a file no longer names the current version", () => {
	const bump = { name: "kevmp/krf", from: "0.1.0", to: "0.2.0" };
	const files = { manifest: MANIFEST, lockfile: LOCKFILE, installDocs: { "README.md": 'KRF = "kevmp/krf@0.1.0"' } };

	assert.match(applyVersionBump({ ...files, manifest: MANIFEST.replace("0.1.0", "0.0.9") }, bump).reason, /wally\.toml/);
	assert.match(applyVersionBump({ ...files, lockfile: LOCKFILE.replace(/krf"\nversion = "0.1.0"/, 'krf"\nversion = "0.0.9"') }, bump).reason, /wally\.lock/);
	assert.match(applyVersionBump({ ...files, installDocs: { "docs.md": "no snippet" } }, bump).reason, /docs\.md/);
});

test("accepts a package listing of root files and Luau source only", () => {
	const listing = ["./default.project.json", "./LICENSE", "./src", "./src/init.luau", ".\\src\\server", ".\\src\\server\\init.luau", "./wally.toml"].join("\n");
	const result = validatePackageListing(listing, new Set(["src", "src/server"]));
	assert.equal(result.ok, true);
	assert.deepEqual(result.files, ["LICENSE", "default.project.json", "src/init.luau", "src/server/init.luau", "wally.toml"]);
});

test("rejects docs, tests, places, secrets and non-Luau files from the package", () => {
	const listing = [
		"./default.project.json",
		"./LICENSE",
		"./wally.toml",
		"./src/init.luau",
		"./README.md",
		"./tests",
		"./KRF.rbxl",
		"./src/.env",
		"./src/server/notes.md",
	].join("\n");
	const result = validatePackageListing(listing, new Set(["tests"]));
	assert.equal(result.ok, false);
	assert.deepEqual(result.unexpected, ["README.md", "tests", "KRF.rbxl", "src/.env", "src/server/notes.md"]);
});

test("reports required package files that are missing", () => {
	const result = validatePackageListing("./wally.toml\n", new Set());
	assert.equal(result.ok, false);
	assert.deepEqual(result.missing, ["default.project.json", "LICENSE", "src/**/*.luau"]);
});

test("rejects archives larger than the registry limit", () => {
	assert.deepEqual(checkArchiveSize(MAX_ARCHIVE_BYTES), { ok: true });
	assert.match(checkArchiveSize(MAX_ARCHIVE_BYTES + 1).reason, /over/);
});

test("compares extracted package trees file by file", (context) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-release-"));
	context.after(() => fs.rmSync(root, { recursive: true, force: true }));

	const write = (tree, file, contents) => {
		fs.mkdirSync(path.dirname(path.join(root, tree, file)), { recursive: true });
		fs.writeFileSync(path.join(root, tree, file), contents);
	};

	write("local", "default.project.json", '{ "name": "krf", "tree": { "$path": "src" } }\n');
	write("local", "src/init.luau", "return {}\n");
	write("registry", "default.project.json", '{\n  "name": "krf",\n  "tree": {\n    "$path": "src"\n  }\n}');
	write("registry", "src/init.luau", "return {}\n");

	const local = hashTree(path.join(root, "local"));
	assert.deepEqual(compareTrees(local, hashTree(path.join(root, "registry"))), { ok: true, missing: [], unexpected: [], changed: [] });

	write("registry", "src/init.luau", "return nil\n");
	write("registry", "src/extra.luau", "return {}\n");
	fs.rmSync(path.join(root, "registry", "default.project.json"));

	assert.deepEqual(compareTrees(local, hashTree(path.join(root, "registry"))), {
		ok: false,
		missing: ["default.project.json"],
		unexpected: ["src/extra.luau"],
		changed: ["src/init.luau"],
	});
});

test("treats a publish as successful only when Wally reports the upload", () => {
	assert.deepEqual(
		classifyPublishResult({ exitCode: 0, stdout: "Publishing kevmp/krf@0.1.0 to x\nPackage published successfully!\n", stderr: "" }),
		{ state: "published" },
	);
});

test("detects an HTTP publish failure even when Wally exits with code zero", () => {
	const outcome = classifyPublishResult({ exitCode: 0, stdout: 'Publishing kevmp/krf@0.1.0 to x\nError: 500 Internal Server Error\n{"message":"boom"}\n', stderr: "" });
	assert.equal(outcome.state, "rejected");
	assert.equal(outcome.status, 500);
	assert.match(outcome.detail, /boom/);
});

test("fails a publish that exits zero without a success report or exits nonzero", () => {
	assert.equal(classifyPublishResult({ exitCode: 0, stdout: "Publishing kevmp/krf@0.1.0 to x\n", stderr: "" }).state, "failed");
	assert.match(
		classifyPublishResult({ exitCode: 1, stdout: "", stderr: "Authentication is required to publish" }).detail,
		/exited with 1: Authentication is required/,
	);
});

test("explains rejected publishes by status", () => {
	assert.match(describeRejection(401), /credentials/);
	assert.match(describeRejection(403), /scope ownership/);
	assert.match(describeRejection(409), /already has this version/);
	assert.match(describeRejection(400), /contents or manifest/);
	assert.match(describeRejection(502), /verify before retrying/);
	assert.match(describeRejection(418), /rejected the publish/);
});

test("names the publish token when the registry reports a GitHub auth failure", () => {
	const detail = 'Error: 422 Unprocessable Entity\n{"message":"Github auth failed because: 404 Not Found"}';
	assert.match(describeRejection(422, detail), /WALLY_PUBLISH_TOKEN.*wally login/);
	assert.match(describeRejection(422, "Error: 422 Unprocessable Entity"), /contents or manifest/);
});

test("lists registry versions from the Git index", async () => {
	const { fetch, calls } = stubFetch([response(200, `${indexLine("0.1.0")}\n${indexLine("0.2.0")}\n`)]);
	assert.deepEqual(await createRegistry({ fetch }).listVersions("kevmp/krf"), { state: "present", versions: ["0.1.0", "0.2.0"] });
	assert.equal(calls[0], "https://raw.githubusercontent.com/UpliftGames/wally-index/main/kevmp/krf");
});

test("reports an absent package only when the index answers 404", async () => {
	const registry = (responses) => createRegistry({ fetch: stubFetch(responses).fetch });
	assert.deepEqual(await registry([response(404)]).listVersions("kevmp/krf"), { state: "absent" });
	assert.equal((await registry([response(500)]).listVersions("kevmp/krf")).state, "unknown");
	assert.equal((await registry([new Error("ECONNRESET")]).listVersions("kevmp/krf")).state, "unknown");
	assert.equal((await registry([response(200, "not json")]).listVersions("kevmp/krf")).state, "unknown");
});

test("downloads exact package contents with the Wally version header", async () => {
	let headers;
	const fetch = async (url, options) => {
		headers = options.headers;
		return url.endsWith("/0.1.0") ? response(200, "zip") : response(404);
	};
	const registry = createRegistry({ fetch });
	const present = await registry.downloadContents("kevmp/krf", "0.1.0");
	assert.equal(present.state, "present");
	assert.equal(present.bytes.toString(), "zip");
	assert.equal(headers["Wally-Version"], "0.3.2");
	assert.deepEqual(await registry.downloadContents("kevmp/krf", "9.9.9"), { state: "absent" });
	assert.equal((await createRegistry({ fetch: stubFetch([response(503)]).fetch }).downloadContents("kevmp/krf", "0.1.0")).state, "unknown");
});

test("waits a bounded number of attempts for a delayed registry publication", async () => {
	const sleeps = [];
	const { fetch } = stubFetch([response(404), response(200, indexLine("0.0.9")), response(200, indexLine("0.1.0")), response(200, "zip")]);
	const result = await createRegistry({ fetch, sleep: async (ms) => sleeps.push(ms) }).awaitVersion("kevmp/krf", "0.1.0", {
		attempts: 5,
		delayMs: 7,
	});
	assert.equal(result.state, "present");
	assert.deepEqual(sleeps, [7, 7]);
});

test("stops waiting after the final attempt and reports the last observed state", async () => {
	const absent = createRegistry({ fetch: stubFetch([response(404), response(404)]).fetch, sleep: async () => {} });
	assert.deepEqual(await absent.awaitVersion("kevmp/krf", "0.1.0", { attempts: 2, delayMs: 0 }), { state: "absent" });

	const unavailable = createRegistry({ fetch: stubFetch([response(404), response(502)]).fetch, sleep: async () => {} });
	assert.equal((await unavailable.awaitVersion("kevmp/krf", "0.1.0", { attempts: 2, delayMs: 0 })).state, "unknown");
});

const TAG = (version, manifestVersion = version) => ({ tag: `v${version}`, version, sha: `${version}`.padEnd(40, "a"), manifestVersion });

test("derives each release state from tags, registry and verified releases", () => {
	const status = deriveReleaseStatus({
		tags: [TAG("0.1.0"), TAG("0.2.0"), TAG("0.3.0"), TAG("0.4.0", "0.3.9")],
		main: { sha: "f".repeat(40), version: "0.5.0" },
		registry: { state: "present", versions: ["0.1.0", "0.2.0", "0.0.1"] },
		verifiedVersions: new Set(["0.1.0"]),
	});

	assert.deepEqual(
		status.rows.map((row) => [row.subject, row.state]),
		[
			["v0.4.0", STATES.mismatch],
			["v0.3.0", STATES.unpublished],
			["v0.2.0", STATES.unverified],
			["v0.1.0", STATES.verified],
			["main", STATES.candidate],
			["0.0.1", STATES.untagged],
		],
	);
	assert.equal(status.latestTag.tag, "v0.4.0");
	assert.equal(status.latestVerified, "0.1.0");
	assert.equal(status.healthy, false);
});

test("never reports tags as unpublished when the registry cannot be read", () => {
	const status = deriveReleaseStatus({
		tags: [TAG("0.1.0")],
		main: { sha: "f".repeat(40), version: "0.1.0" },
		registry: { state: "unknown", reason: "Index returned HTTP 503" },
		verifiedVersions: new Set(["0.1.0"]),
	});

	assert.deepEqual(status.rows.map((row) => row.state), [STATES.unknown]);
	assert.equal(status.latestVerified, null);
	assert.match(renderReleaseStatus(status, "0.1.0"), /Unknown \(Index returned HTTP 503\)/);
});

test("reports a clean state for a verified release and an untagged main candidate", () => {
	const status = deriveReleaseStatus({
		tags: [TAG("0.1.0")],
		main: { sha: "f".repeat(40), version: "0.2.0" },
		registry: { state: "present", versions: ["0.1.0"] },
		verifiedVersions: new Set(["0.1.0"]),
	});

	assert.equal(status.healthy, true);
	const summary = renderReleaseStatus(status, "0.2.0");
	assert.match(summary, /\| Latest release tag \| v0.1.0/);
	assert.match(summary, /\| Latest verified registry version \| 0.1.0 \|/);
	assert.match(summary, /\| main \| `ffffffffffff` \| 0.2.0 \| Candidate on main \(not yet tagged\) \|/);
});

test("reports no release before the first tag or publication", () => {
	const status = deriveReleaseStatus({
		tags: [],
		main: { sha: "f".repeat(40), version: "0.1.0" },
		registry: { state: "absent" },
		verifiedVersions: new Set(),
	});

	assert.deepEqual(status.rows.map((row) => row.state), [STATES.candidate]);
	const summary = renderReleaseStatus(status, "0.1.0");
	assert.match(summary, /\| Latest release tag \| None \|/);
	assert.match(summary, /\| Registry versions \| No published versions \|/);
});
