import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { runDeployment } from "../src/deploy/cli.js";
import { readTargets } from "../src/deploy/config.js";
import { githubClient } from "../src/deploy/github.js";
import { withPublishJournal } from "../src/deploy/journal.js";
import { openCloud, PLACE_PUBLISHER } from "../src/deploy/open-cloud.js";
import { inspectPlace } from "../src/deploy/place.js";
import { publishPlaces } from "../src/deploy/place-set.js";
import { nextVersion, openReleasePullRequest, tagRelease } from "../src/deploy/release.js";
import { readLocalProject } from "../src/workflow/project.js";

const commit = "a".repeat(40);
const deployment = {
	owner: { kind: "group", id: "11" },
	developers: { alex: { universeId: "21", placeId: "31" }, sam: { universeId: "22", placeId: "32" } },
	qa: { universeId: "25", placeId: "35" },
	production: { universeId: "26", placeId: "36" },
};
const dev = { environment: "dev", name: "alex", ...deployment.developers.alex, owner: deployment.owner };
const json = (data, status = 200) => Response.json(data, { status });

function fixture(t, { config = deployment, hybrid = false, layout = {} } = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-cloud-test-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const write = (file, content) => {
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), content);
	};
	write("package.json", JSON.stringify({ name: "test-game", krf: { ...layout, deployment: config } }));
	write("default.project.json", "{}");
	write("wally.toml", "");
	if (hybrid) write("start-place.project.json", "{}");
	return { root, write };
}

function chunk(name, data) {
	const header = Buffer.alloc(16);
	header.write(name);
	header.writeUInt32LE(data.length, 8);
	return Buffer.concat([header, data]);
}

function place(...classes) {
	const names = ["Workspace", ...classes];
	const header = Buffer.alloc(32);
	Buffer.from("3c726f626c6f782189ff0d0a1a0a0000", "hex").copy(header);
	header.writeUInt32LE(names.length, 16);
	header.writeUInt32LE(names.length, 20);
	const instances = names.map((name, id) => {
		const data = Buffer.alloc(17 + name.length);
		data.writeUInt32LE(id);
		data.writeUInt32LE(name.length, 4);
		data.write(name, 8);
		data.writeUInt32LE(1, 9 + name.length);
		return chunk("INST", data);
	});
	const parents = Buffer.alloc(5 + 8 * names.length);
	parents.writeUInt32LE(names.length, 1);
	return Buffer.concat([header, ...instances, chunk("PRNT", parents), chunk("END", Buffer.from("</roblox>"))]);
}

const git = {
	spawnSync(command, args) {
		assert.equal(command, "git");
		return { status: 0, stdout: args[1] === "--verify" ? commit : "" };
	},
};

async function cli(project, command, { env = {}, fetch = () => assert.fail("unexpected network request"), system = git } = {}) {
	let output = "";
	const io = { cwd: project.root, stdout: (value) => output += value, stderr: (value) => assert.fail(value) };
	const exitCode = await runDeployment([...command, "--json"], io, { system: { ...system, env }, fetch, cloudOptions: { sleep: async () => {} } });
	return { exitCode, raw: output, ...JSON.parse(output) };
}

test("environment listing is read-only and reports credential presence without revealing the key", async (t) => {
	const project = fixture(t);
	const result = await cli(project, ["env:list"], { env: { KRF_ROBLOX_DEV_KEY: "private-test-key" } });
	assert.equal(result.exitCode, 0);
	assert.equal(result.targets.length, 4);
	assert.equal(result.targets[0].credential, "present");
	assert.equal(result.targets[0].ownershipVerification, "unverified");
	assert.equal(result.targets[2].credential, "missing");
	assert.doesNotMatch(result.raw, /private-test-key/);
	assert.equal((await cli(project, ["open:dev"])).code, "target-not-configured");
	assert.equal((await cli(project, ["open:dev", "--developer", "qa"])).code, "target-not-configured");
	assert.equal((await cli(project, ["open:dev", "--developer", "alex"])).target.placeId, "31");
});

test("Dev reads project-local credentials with process overrides and ignores QA secrets from the file", async (t) => {
	const project = fixture(t);
	project.write(".env", "KRF_DEVELOPER=alex\nKRF_ROBLOX_DEV_KEY=local-dev\nKRF_ROBLOX_QA_KEY=local-qa\n");
	const result = await cli(project, ["env:list"]);
	assert.equal(result.targets[0].credential, "present");
	assert.equal(result.targets[2].credential, "missing");
	assert.doesNotMatch(result.raw, /local-(dev|qa)/);
	assert.equal((await cli(project, ["open:dev"])).target.name, "alex");
	assert.equal((await cli(project, ["env:list"], { env: { KRF_ROBLOX_DEV_KEY: "" } })).targets[0].credential, "missing");
});

test("deployment rejects overlapping targets, Hybrid overlays and direct privileged commands", async (t) => {
	const broken = fixture(t, { config: { ...deployment, production: { ...deployment.production, universeId: "21" } } });
	assert.equal((await cli(broken, ["env:list"])).code, "overlapping-targets");
	const hybrid = fixture(t, { hybrid: true });
	assert.equal((await cli(hybrid, ["env:list"])).mode, "hybrid");
	assert.equal((await cli(hybrid, ["deploy:dev", "--developer", "alex"])).code, "unsupported-project-mode");
	for (const command of ["deploy:prod", "release:tag", "release:pr"]) {
		assert.equal((await cli(fixture(t), [command])).code, "github-required");
	}
});

test("Dev publishing refuses a key without Roblox-confirmed ownership or Assets access", async (t) => {
	const project = fixture(t);
	const env = { KRF_ROBLOX_DEV_KEY: "secret" };
	assert.equal((await cli(project, ["deploy:dev", "--developer", "alex"], { env: {} })).code, "missing-credential");
	const fetch = async (url, options) => {
		assert.equal(options.method, "GET");
		const resource = new URL(url).pathname.replace("/cloud/v2/", "");
		if (resource === "universes/21") return json({ path: resource, group: "groups/12" });
		return json({ path: resource });
	};
	assert.equal((await cli(project, ["deploy:dev", "--developer", "alex"], { env, fetch })).code, "roblox-target-mismatch");
	const broad = async (url, options) => {
		if (options.method === "POST") return json({ enabled: true, expired: false, scopes: [{ name: "asset", operations: ["write"], groupIds: ["11"] }] });
		const resource = new URL(url).pathname.replace("/cloud/v2/", "");
		return json({ path: resource, group: "groups/11" });
	};
	assert.equal((await cli(project, ["deploy:dev", "--developer", "alex"], { env, fetch: broad })).code, "place-write-scope-unverified");
});

test("a private universe with omitted group metadata is recorded as owner-unreported", async () => {
	const cloud = openCloud("fixture-key", { fetch: async (url) => json({ path: new URL(url).pathname.replace("/cloud/v2/", "") }) });
	assert.equal(await cloud.verifyTarget(dev), "owner-unreported");
});

test("place key introspection requires Assets read and write access for the owning group", async () => {
	for (const [scopes, expected] of [
		[[{ name: "asset", operations: ["read", "write"], groupIds: ["11"] }], undefined],
		[[{ name: "asset", operations: ["read"], groupIds: ["11"] }, { name: "asset", operations: ["write"], groupIds: ["*"] }], undefined],
		[[{ name: "asset", operations: ["read", "write"], universeIds: ["21"] }], undefined],
		[[{ name: "asset", operations: ["write"], groupIds: ["11"] }], "place-write-scope-unverified"],
		[[{ name: "asset", operations: ["read", "write"], groupIds: ["12"] }], "place-write-scope-unverified"],
		[[{ name: "universe-places", operations: ["write"], universeIds: ["21"] }], "place-write-scope-unverified"],
	]) {
		const cloud = openCloud("fixture-key", {
			async fetch(url, { method, body }) {
				assert.equal(url, "https://apis.roblox.com/api-keys/v1/introspect");
				assert.equal(method, "POST");
				assert.equal(JSON.parse(body).apiKey, "fixture-key");
				return json({ enabled: true, expired: false, scopes });
			},
		});
		if (expected) await assert.rejects(cloud.verifyPlaceKey(dev), { code: expected });
		else await cloud.verifyPlaceKey(dev);
	}
});

test("place publishing uploads the exact binary once as a published Assets version and polls its operation", async () => {
	const bytes = place();
	const progress = [];
	let writes = 0;
	let polls = 0;
	const cloud = openCloud("fixture-key", {
		sleep: async () => {},
		async fetch(url, { method, headers, body, redirect }) {
			assert.equal(headers["x-api-key"], "fixture-key");
			assert.equal(redirect, "error");
			if (method === "PATCH") {
				assert.equal(url, "https://apis.roblox.com/assets/v1/assets/31");
				assert.deepEqual(JSON.parse(body.get("request")), { assetId: 31, assetType: "Place", published: true });
				assert.equal(body.get("fileContent").type, "application/octet-stream");
				assert.deepEqual(Buffer.from(await body.get("fileContent").arrayBuffer()), bytes);
				writes++;
				return json({ path: "operations/place" });
			}
			assert.equal(url, "https://apis.roblox.com/assets/v1/operations/place");
			polls++;
			return polls === 1
				? json({ path: "operations/place", done: false })
				: json({ path: "operations/place", done: true, response: { path: "assets/31", revisionId: "54", isPublished: true } });
		},
	});
	const result = await cloud.publish(dev, { bytes }, (entry) => progress.push(entry));
	assert.deepEqual(result, { status: "confirmed-published", revisionId: "54", publisher: PLACE_PUBLISHER, operationId: "place" });
	assert.deepEqual(progress, [{ status: "submitted", operationId: "place" }]);
	assert.equal(writes, 1);
	assert.equal(polls, 2);
});

test("failed and uncertain publish responses never produce an invented revision or a retry", async () => {
	const done = (response) => () => json({ path: "operations/place", done: true, ...response });
	for (const [submit, poll, expected] of [
		[() => json({}), undefined, "unknown"],
		[() => new Response("untrusted body", { status: 200 }), undefined, "unknown"],
		[() => json({}, 403), undefined, "failed"],
		[() => json({}, 429), undefined, "failed"],
		[() => json({}, 500), undefined, "unknown"],
		[() => { throw new Error("connection dropped"); }, undefined, "unknown"],
		[() => json({ path: "operations/place" }), done({ error: { code: 3, message: "invalid place" } }), "failed"],
		[() => json({ path: "operations/place" }), done({ error: { code: "Unknown", message: "Save failed.", details: [{ reason: "PlaceOngoingTeamCreateSession" }] } }), "failed"],
		[() => json({ path: "operations/place" }), done({ response: { path: "assets/31", revisionId: "54", isPublished: false } }), "unknown"],
		[() => json({ path: "operations/place" }), done({ response: { path: "assets/32", revisionId: "54", isPublished: true } }), "unknown"],
		[() => json({ path: "operations/place" }), done({ response: { path: "assets/31", revisionId: "0", isPublished: true } }), "unknown"],
		[() => json({ path: "operations/place" }), () => json({}, 404), "unknown"],
	]) {
		let writes = 0;
		const cloud = openCloud("fixture-key", {
			sleep: async () => {},
			async fetch(_url, { method }) {
				if (method === "GET") return poll();
				assert.equal(method, "PATCH");
				writes++;
				return submit();
			},
		});
		const result = await cloud.publish(dev, { bytes: place() });
		assert.equal(result.status, expected);
		assert.equal(result.publisher, PLACE_PUBLISHER);
		assert.equal(result.revisionId, undefined);
		assert.doesNotMatch(JSON.stringify(result), /untrusted body|fixture-key/);
		assert.equal(writes, 1);
	}
});

test("an uncertain publish keeps the target locked and preserves its operation ID", async (t) => {
	const project = fixture(t);
	const key = `test-${randomUUID()}`;
	const lease = path.join(os.tmpdir(), "krf-open-cloud", `${key}.jsonl`);
	t.after(() => fs.rmSync(lease, { force: true }));
	const { promise, resolve } = Promise.withResolvers();
	const active = withPublishJournal(key, {}, async (progress) => {
		progress({ status: "submitted", operationId: "op" });
		return promise;
	});
	await assert.rejects(withPublishJournal(key, {}, () => assert.fail("second writer")), { code: "publish-in-flight" });
	resolve({ status: "unknown", operationId: "op" });
	const result = await active;
	assert.equal(result.status, "unknown");
	await assert.rejects(withPublishJournal(key, {}, () => assert.fail("unsafe retry")), { code: "publish-in-flight" });
	assert.match(fs.readFileSync(result.lease, "utf8"), /"status":"submitted","operationId":"op"/);
});

test("place inspection accepts a complete binary place and rejects malformed artifacts", () => {
	const original = inspectPlace(place("SurfaceAppearance"));
	assert.equal(original.placeSha256.length, 64);
	assert.throws(() => inspectPlace(original.bytes.subarray(0, -1)), { code: "unsupported-place-artifact" });
	assert.throws(() => inspectPlace(Buffer.from("<roblox/>")), { code: "unsupported-place-artifact" });
});

const multiLayout = { startPlace: "lobby", placeProjects: { lobby: "default.project.json", dungeon: "dungeon.project.json", arena: "arena.project.json" } };
const multiDeployment = {
	owner: deployment.owner, developers: { alex: { universeId: "21", places: { lobby: "31", dungeon: "32", arena: "33" } } },
	qa: { universeId: "25", places: { lobby: "35", dungeon: "36", arena: "37" } },
	production: { universeId: "26", places: { lobby: "61", dungeon: "62", arena: "63" } },
};

test("a named place set requires complete distinct place mappings per universe", async (t) => {
	const project = fixture(t, { config: multiDeployment, layout: multiLayout });
	assert.equal(readTargets(project)[0].places.dungeon.placeId, "32");
	assert.equal((await cli(project, ["open:dev", "--developer", "alex"])).target.placeId, "31");
	assert.equal((await cli(project, ["open:dev", "--developer", "alex", "--place", "dungeon"])).target.placeId, "32");
	const broken = structuredClone(multiDeployment);
	delete broken.qa.places.dungeon;
	assert.throws(() => readTargets(fixture(t, { config: broken, layout: multiLayout })), { code: "invalid-deployment-config" });
	broken.qa.places.dungeon = "32";
	assert.throws(() => readTargets(fixture(t, { config: broken, layout: multiLayout })), { code: "overlapping-targets" });
});

test("a rejected publish reports Roblox's reason", async () => {
	const cloud = openCloud("fixture-key", {
		sleep: async () => {},
		fetch: async (_url, { method }) => method === "PATCH"
			? json({ path: "operations/place" })
			: json({ path: "operations/place", done: true, error: { code: "Unknown", message: "Save failed.", details: [{ reason: "PlaceOngoingTeamCreateSession", domain: "roblox" }] } }),
	});
	const result = await cloud.publish(dev, { bytes: place() });
	assert.equal(result.status, "failed");
	assert.deepEqual(result.robloxError, { code: "Unknown", message: "Save failed.", reason: "PlaceOngoingTeamCreateSession" });
});

test("publishes destinations before the start place and stops on partial failure", async (t) => {
	const project = fixture(t, { config: multiDeployment, layout: multiLayout });
	const target = { ...readTargets(project)[0], universeId: `9${Date.now()}` };
	const lease = path.join(os.tmpdir(), "krf-open-cloud", `universe-${target.universeId}.jsonl`);
	t.after(() => fs.rmSync(lease, { force: true }));
	const artifacts = new Map(Object.keys(target.places).map((name) => [name, inspectPlace(place())]));
	const seen = [];
	const cloud = {
		async publish(placeTarget) {
			seen.push(placeTarget.placeId);
			return placeTarget.placeId === "32" ? { status: "failed" } : { status: "confirmed-published", revisionId: "7" };
		},
	};
	const result = await publishPlaces(cloud, target, artifacts, {});
	assert.deepEqual(seen, ["33", "32"]);
	assert.equal(result.status, "partial");
	assert.equal(result.places.arena.revisionId, "7");
	assert.equal(result.places.lobby.status, "not-attempted");
	assert.equal(result.lease, undefined);
	const announced = [];
	assert.equal((await publishPlaces(cloud, target, artifacts, {}, (name) => announced.push(name))).status, "partial");
	assert.deepEqual(announced, ["arena", "dungeon"]);
});

test("an unconfirmed place in a set keeps the universe locked", async (t) => {
	const project = fixture(t, { config: multiDeployment, layout: multiLayout });
	const target = { ...readTargets(project)[0], universeId: `8${Date.now()}` };
	const lease = path.join(os.tmpdir(), "krf-open-cloud", `universe-${target.universeId}.jsonl`);
	t.after(() => fs.rmSync(lease, { force: true }));
	const artifacts = new Map(Object.keys(target.places).map((name) => [name, inspectPlace(place())]));
	const cloud = { publish: async (placeTarget) => placeTarget.placeId === "33" ? { status: "confirmed-published", revisionId: "7" } : { status: "unknown", operationId: "op" } };
	t.after(() => fs.rmSync(path.join(os.tmpdir(), "krf-open-cloud", "place-32.jsonl"), { force: true }));
	const result = await publishPlaces(cloud, target, artifacts, {});
	assert.equal(result.status, "unknown");
	assert.equal(result.lease, lease);
	assert.equal(result.places.dungeon.lease, path.join(os.tmpdir(), "krf-open-cloud", "place-32.jsonl"));
	await assert.rejects(publishPlaces(cloud, target, artifacts, {}), { code: "publish-in-flight" });
});

const githubEnv = { GITHUB_REPOSITORY: "group/game", KRF_GITHUB_TOKEN: "fixture-gh-key", GITHUB_REF: "refs/tags/v1.2.0", GITHUB_REF_NAME: "v1.2.0" };

function releaseProject(t, version = "1.2.0") {
	const project = fixture(t);
	const manifest = JSON.parse(fs.readFileSync(path.join(project.root, "package.json"), "utf8"));
	project.write("package.json", `${JSON.stringify({ ...manifest, version }, null, 2)}\n`);
	return project;
}

function githubFetch({ tags = { "v1.2.0": commit }, onMain = true, qaJobs = [{ name: "qa", conclusion: "success" }], writes = [] } = {}) {
	return async (url, { method, headers, body }) => {
		assert.equal(headers.authorization, "Bearer fixture-gh-key");
		const { pathname, searchParams } = new URL(url);
		const resource = pathname.replace("/repos/group/game", "");
		if (method === "POST") {
			writes.push({ resource, body: JSON.parse(body) });
			if (resource.endsWith("/dispatches")) return new Response(null, { status: 204 });
			return json(resource === "/pulls" ? { html_url: "https://github.com/group/game/pull/7" } : {}, 201);
		}
		const tag = /^\/git\/ref\/tags\/(.+)$/.exec(resource)?.[1];
		if (tag) return tags[tag] ? json({ object: { type: "commit", sha: tags[tag] } }) : json({}, 404);
		if (resource === `/compare/${commit}...main`) return json({ status: onMain ? "ahead" : "diverged" });
		if (resource === "/actions/workflows/deploy.yml/runs") {
			assert.equal(searchParams.get("head_sha"), commit);
			return json({ workflow_runs: [{ id: 5, head_sha: commit }] });
		}
		if (resource === "/actions/runs/5/jobs") return json({ jobs: qaJobs });
		assert.fail(`${method} ${resource}`);
	};
}

async function roblox(url, { method }) {
	if (method === "POST") return json({ enabled: true, expired: false, scopes: [{ name: "asset", operations: ["read", "write"], groupIds: ["11"] }] });
	const resource = new URL(url).pathname.replace("/cloud/v2/", "");
	return json({ path: resource, group: "groups/11" });
}

test("QA deploys any clean commit while Production requires the main release tag that already passed QA", async (t) => {
	const project = releaseProject(t);
	const dirty = { spawnSync: (_command, args) => ({ status: 0, stdout: args[1] === "--verify" ? commit : args[0] === "status" ? " M src/Game.luau" : "" }) };
	assert.equal((await cli(project, ["deploy:qa"], { env: { KRF_ROBLOX_QA_KEY: "qa" }, system: dirty })).code, "dirty-worktree");
	const qa = await cli(project, ["deploy:qa", "--verify-target"], { env: { KRF_ROBLOX_QA_KEY: "qa", GITHUB_REF_NAME: "feature/arena" }, fetch: roblox });
	assert.equal(qa.status, "validated");
	assert.equal(qa.ref, "feature/arena");
	assert.equal(qa.target.placeId, "35");

	const production = (options = {}, env = {}) => cli(project, ["deploy:prod", "--verify-target"], {
		env: { ...githubEnv, KRF_ROBLOX_PROD_KEY: "prod", ...env },
		fetch: (url, request) => url.startsWith("https://apis.roblox.com/") ? roblox(url, request) : githubFetch(options)(url, request),
	});
	assert.equal((await production({}, { GITHUB_REF: "refs/heads/main" })).code, "release-tag-required");
	assert.equal((await production({}, { GITHUB_REF: "refs/tags/v1.1.0" })).code, "release-tag-required");
	assert.equal((await production({ tags: { "v1.2.0": "b".repeat(40) } })).code, "release-tag-mismatch");
	assert.equal((await production({ onMain: false })).code, "release-not-on-main");
	assert.equal((await production({ qaJobs: [{ name: "qa", conclusion: "failure" }, { name: "prod", conclusion: "success" }] })).code, "qa-not-deployed");
	const verified = await production();
	assert.equal(verified.status, "validated");
	assert.equal(verified.tag, "v1.2.0");
	assert.equal(verified.target.placeId, "36");
});

test("release versions bump from the current version and only move forward", () => {
	assert.equal(nextVersion("0.0.0", "patch"), "0.0.1");
	assert.equal(nextVersion("1.2.3", "minor"), "1.3.0");
	assert.equal(nextVersion("1.2.3", "major"), "2.0.0");
	assert.equal(nextVersion("1.2.3", "1.10.0"), "1.10.0");
	for (const to of ["1.2.3", "1.1.9", "latest", "1.3.0-beta"]) assert.throws(() => nextVersion("1.2.3", to), { code: "invalid-version" });
});

test("a release pull request bumps the version on its own branch and refuses a release that was never tagged", async (t) => {
	const project = releaseProject(t);
	project.write("package-lock.json", `${JSON.stringify({ name: "test-game", version: "1.2.0", lockfileVersion: 3, packages: { "": { name: "test-game", version: "1.2.0" } } }, null, 2)}\n`);
	const commands = [];
	const system = {
		env: {},
		spawnSync(command, args) {
			commands.push(args.join(" "));
			return git.spawnSync(command, args);
		},
	};
	const writes = [];
	const result = await openReleasePullRequest(system, readLocalProject(project.root), githubClient(githubEnv, githubFetch({ writes })), "minor");
	assert.equal(result.tag, "v1.3.0");
	assert.equal(result.url, "https://github.com/group/game/pull/7");
	assert.equal(JSON.parse(fs.readFileSync(path.join(project.root, "package.json"), "utf8")).version, "1.3.0");
	const lock = JSON.parse(fs.readFileSync(path.join(project.root, "package-lock.json"), "utf8"));
	assert.deepEqual([lock.version, lock.packages[""].version], ["1.3.0", "1.3.0"]);
	assert.deepEqual(commands.filter((command) => !/^(rev-parse|status)\b/.test(command)), [
		"switch --create release/v1.3.0",
		"add -- package.json package-lock.json",
		"commit --message chore(release): v1.3.0",
		"push --set-upstream origin release/v1.3.0",
	]);
	assert.deepEqual(writes.map(({ resource, body }) => [resource, body.head, body.base, body.title]), [["/pulls", "release/v1.3.0", "main", "chore(release): v1.3.0"]]);
	await assert.rejects(openReleasePullRequest(system, readLocalProject(project.root), githubClient(githubEnv, githubFetch({ tags: {} })), "patch"), { code: "release-pending" });
});

test("merging a version change tags its commit once and dispatches the QA deploy", async (t) => {
	const project = releaseProject(t);
	const previous = (version) => ({
		env: {},
		spawnSync: (command, args) => args[0] === "show" ? { status: 0, stdout: JSON.stringify({ version }) } : git.spawnSync(command, args),
	});
	const writes = [];
	const unchanged = await tagRelease(previous("1.2.0"), readLocalProject(project.root), githubClient(githubEnv, githubFetch({ writes })));
	assert.equal(unchanged.released, false);
	assert.deepEqual(writes, []);
	const released = await tagRelease(previous("1.1.0"), readLocalProject(project.root), githubClient(githubEnv, githubFetch({ tags: {}, writes })));
	assert.equal(released.tag, "v1.2.0");
	assert.deepEqual(writes, [
		{ resource: "/git/refs", body: { ref: "refs/tags/v1.2.0", sha: commit } },
		{ resource: "/actions/workflows/deploy.yml/dispatches", body: { ref: "v1.2.0", inputs: { target: "qa" } } },
	]);
	await assert.rejects(tagRelease(previous("1.1.0"), readLocalProject(project.root), githubClient(githubEnv, githubFetch({ tags: { "v1.2.0": "b".repeat(40) } }))),
		{ code: "release-exists" });
});
