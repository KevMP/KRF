#!/usr/bin/env node
// KRF Wally release tasks used by .github/workflows/release-pr.yml, release-wally.yml and
// release-status.yml.
//
//   node scripts/release-wally.cjs bump --to patch|minor|major|X.Y.Z
//   node scripts/release-wally.cjs resolve --commit <sha> | --tag vX.Y.Z
//   node scripts/release-wally.cjs preflight --tag vX.Y.Z
//   node scripts/release-wally.cjs publish
//   node scripts/release-wally.cjs verify-registry --version X.Y.Z
//   node scripts/release-wally.cjs consumer --source archive|registry [--version X.Y.Z] --out <dir>
//   node scripts/release-wally.cjs status
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const { parseReleaseTag, readPackageManifest, checkTagMatchesManifest, decideRelease } = require("./release/manifest.cjs");
const { nextVersion, applyVersionBump } = require("./release/bump.cjs");
const { validatePackageListing, checkArchiveSize, hashTree, compareTrees } = require("./release/archive.cjs");
const { createRegistry } = require("./release/registry.cjs");
const { classifyPublishResult, describeRejection } = require("./release/publish.cjs");
const { deriveReleaseStatus, renderReleaseStatus, STATES } = require("./release/status.cjs");

const REPO_ROOT = path.resolve(__dirname, "..");
const WORK_DIR = path.join(REPO_ROOT, "build", "release");
const ARCHIVE_PATH = path.join(WORK_DIR, "krf.zip");
const SMOKE_TASK = path.join(REPO_ROOT, "tests", "consumer", "Smoke.luau");
// Pages whose install snippet names the current runtime version; release PRs update them.
const INSTALL_DOCS = ["README.md", "docs-site/docs/documentation/initializing-krf.md"];

class ReleaseError extends Error {}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, { cwd: REPO_ROOT, encoding: "utf8", ...options });
	if (result.error) throw new ReleaseError(`${command} could not start: ${result.error.message}`);
	return { exitCode: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

function runChecked(command, args, options = {}) {
	const result = run(command, args, options);
	if (result.exitCode !== 0) {
		throw new ReleaseError(`${command} ${args.join(" ")} failed (${result.exitCode}):\n${result.stderr || result.stdout}`);
	}
	return result.stdout;
}

function parseOptions(args) {
	const options = {};
	for (let index = 0; index < args.length; index += 1) {
		const key = args[index];
		if (!key.startsWith("--")) throw new ReleaseError(`Unexpected argument '${key}'`);
		const value = args[index + 1];
		if (value === undefined || value.startsWith("--")) throw new ReleaseError(`${key} requires a value`);
		options[key.slice(2)] = value;
		index += 1;
	}
	return options;
}

function setOutput(name, value) {
	if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
	console.log(`${name}=${value}`);
}

function writeSummary(markdown) {
	if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown);
	console.log(markdown);
}

/** Returns the commit a tag names, or null when the tag does not exist. */
function tagCommit(tag) {
	const result = run("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${tag}^{commit}`]);
	return result.exitCode === 0 ? result.stdout.trim() : null;
}

function readManifest(text = fs.readFileSync(path.join(REPO_ROOT, "wally.toml"), "utf8")) {
	return readPackageManifest(text);
}

/** Builds the package archive and confirms it holds only the intended files. */
function buildArchive() {
	const listing = runChecked("wally", ["package", "--list"]);
	const directories = new Set();
	for (const line of listing.split(/\r?\n/)) {
		const entry = line.trim().replace(/\\/g, "/").replace(/^\.\//, "");
		if (entry !== "" && fs.statSync(path.join(REPO_ROOT, entry)).isDirectory()) directories.add(entry);
	}

	const contents = validatePackageListing(listing, directories);
	if (!contents.ok) {
		throw new ReleaseError(
			`Package contents are not publishable.\nUnexpected: ${contents.unexpected.join(", ") || "none"}\nMissing: ${contents.missing.join(", ") || "none"}`,
		);
	}

	fs.mkdirSync(WORK_DIR, { recursive: true });
	fs.rmSync(ARCHIVE_PATH, { force: true });
	runChecked("wally", ["package", "--output", ARCHIVE_PATH]);

	const size = checkArchiveSize(fs.statSync(ARCHIVE_PATH).size);
	if (!size.ok) throw new ReleaseError(size.reason);

	return contents.files;
}

function extract(archivePath, destination) {
	fs.rmSync(destination, { recursive: true, force: true });
	fs.mkdirSync(destination, { recursive: true });
	runChecked("unzip", ["-q", archivePath, "-d", destination]);
}

/** Writes the next version into wally.toml, wally.lock and the install snippets. */
function bump(options) {
	if (!options.to) throw new ReleaseError("bump requires --to patch|minor|major|X.Y.Z");

	const manifest = readManifest();
	if (tagCommit(`v${manifest.version}`) === null) {
		throw new ReleaseError(
			`main declares ${manifest.version}, which is not released yet. Let its release finish before preparing another.`,
		);
	}

	const next = nextVersion(manifest.version, options.to);
	if (!next.ok) throw new ReleaseError(next.reason);
	if (tagCommit(`v${next.version}`) !== null) throw new ReleaseError(`v${next.version} is already tagged`);

	const read = (file) => fs.readFileSync(path.join(REPO_ROOT, file), "utf8");
	const bumped = applyVersionBump(
		{
			manifest: read("wally.toml"),
			lockfile: read("wally.lock"),
			installDocs: Object.fromEntries(INSTALL_DOCS.map((file) => [file, read(file)])),
		},
		{ name: manifest.name, from: manifest.version, to: next.version },
	);
	if (!bumped.ok) throw new ReleaseError(bumped.reason);

	fs.writeFileSync(path.join(REPO_ROOT, "wally.toml"), bumped.manifest);
	fs.writeFileSync(path.join(REPO_ROOT, "wally.lock"), bumped.lockfile);
	for (const [file, text] of Object.entries(bumped.installDocs)) fs.writeFileSync(path.join(REPO_ROOT, file), text);

	setOutput("previous", manifest.version);
	setOutput("version", next.version);
	setOutput("tag", `v${next.version}`);
}

/**
 * Chooses what a release run publishes: the version a main commit declares, or an existing tag
 * named for a manual rerun.
 */
function resolve(options) {
	if (options.tag) {
		const parsed = parseReleaseTag(options.tag);
		if (!parsed.ok) throw new ReleaseError(parsed.reason);

		const commit = tagCommit(options.tag);
		if (commit === null) throw new ReleaseError(`Tag ${options.tag} does not exist`);

		setOutput("release", "true");
		setOutput("tag", options.tag);
		setOutput("commit", commit);
		setOutput("create_tag", "false");
		return;
	}

	const commit = runChecked("git", ["rev-parse", options.commit ?? "HEAD"]).trim();
	const manifest = readPackageManifest(runChecked("git", ["show", `${commit}:wally.toml`]));
	if (manifest.private) throw new ReleaseError("wally.toml marks the package private");

	const decision = decideRelease({ version: manifest.version, commit, taggedCommit: tagCommit(`v${manifest.version}`) });
	setOutput("release", String(decision.release));
	setOutput("tag", decision.tag);
	setOutput("commit", commit);
	setOutput("create_tag", String(decision.release && decision.createTag));

	if (!decision.release) {
		writeSummary(`- Nothing to release: ${decision.reason}\n`);
	} else {
		const resumed = decision.createTag ? "" : " (resuming its existing tag)";
		writeSummary(`- Releasing \`${manifest.name}@${manifest.version}\` from \`${commit}\`${resumed}\n`);
	}
}

/** Validates the checked-out commit for its release tag, which is created only after preflight. */
async function preflight(options) {
	const tag = options.tag;
	const manifest = readManifest();
	const identity = checkTagMatchesManifest(tag, manifest);
	if (!identity.ok) throw new ReleaseError(identity.reason);

	const head = runChecked("git", ["rev-parse", "HEAD"]).trim();
	const tagged = tagCommit(tag);
	if (tagged !== null && head !== tagged) {
		throw new ReleaseError(`Checked-out commit ${head} is not the commit tagged ${tag} (${tagged})`);
	}

	const onMain = run("git", ["merge-base", "--is-ancestor", head, "origin/main"]);
	if (onMain.exitCode !== 0) throw new ReleaseError(`${head} is not reachable from origin/main`);

	const files = buildArchive();
	const listing = await createRegistry().listVersions(manifest.name);
	if (listing.state === "unknown") throw new ReleaseError(`Registry state is unknown: ${listing.reason}`);
	const alreadyPublished = listing.state === "present" && listing.versions.includes(identity.version);

	setOutput("package", manifest.name);
	setOutput("version", identity.version);
	setOutput("commit", head);
	setOutput("already_published", String(alreadyPublished));

	writeSummary(
		[
			`## Preflight ${tag}`,
			"",
			`- Package: \`${manifest.name}@${identity.version}\``,
			`- Commit: \`${head}\` (reachable from main${tagged === null ? "; tagged after preflight" : ""})`,
			`- Archive: ${files.length} files, ${fs.statSync(ARCHIVE_PATH).size} bytes`,
			`- Registry: ${alreadyPublished ? "version already published; verifying instead of publishing" : "version not yet published"}`,
			"",
		].join("\n"),
	);
}

function publish() {
	const manifest = readManifest();
	const result = run("wally", ["publish"]);
	const outcome = classifyPublishResult(result);

	if (outcome.state === "rejected") {
		throw new ReleaseError(`${describeRejection(outcome.status)} (HTTP ${outcome.status}).\n${outcome.detail}`);
	}
	if (outcome.state === "failed") throw new ReleaseError(outcome.detail);

	writeSummary(`- Uploaded \`${manifest.name}@${manifest.version}\`; awaiting registry readback\n`);
}

async function verifyRegistry(options) {
	const manifest = readManifest();
	const version = options.version ?? manifest.version;
	if (version !== manifest.version) throw new ReleaseError(`Requested ${version} but wally.toml is ${manifest.version}`);

	buildArchive();

	const contents = await createRegistry().awaitVersion(manifest.name, version, {
		attempts: Number(options.attempts ?? 10),
		delayMs: Number(options["delay-ms"] ?? 15000),
	});

	if (contents.state === "absent") throw new ReleaseError(`${manifest.name}@${version} is not in the registry`);
	if (contents.state === "unknown") throw new ReleaseError(`Registry state is unknown: ${contents.reason}`);

	const registryArchive = path.join(WORK_DIR, "registry.zip");
	fs.writeFileSync(registryArchive, contents.bytes);
	extract(ARCHIVE_PATH, path.join(WORK_DIR, "local"));
	extract(registryArchive, path.join(WORK_DIR, "registry"));

	const comparison = compareTrees(hashTree(path.join(WORK_DIR, "local")), hashTree(path.join(WORK_DIR, "registry")));
	if (!comparison.ok) {
		throw new ReleaseError(
			`Registry archive differs from the tagged source.\nMissing: ${comparison.missing.join(", ") || "none"}\nUnexpected: ${comparison.unexpected.join(", ") || "none"}\nChanged: ${comparison.changed.join(", ") || "none"}`,
		);
	}

	writeSummary(`- Registry serves \`${manifest.name}@${version}\` with contents identical to the tagged source\n`);
}

/** Creates an isolated consumer place that mounts KRF exactly as `wally install` does. */
function prepareConsumer(options) {
	const manifest = readManifest();
	const source = options.source;
	const version = options.version ?? manifest.version;
	if (!options.out) throw new ReleaseError("consumer requires --out");
	if (source !== "archive" && source !== "registry") throw new ReleaseError("consumer --source must be archive or registry");

	const consumerDir = path.resolve(REPO_ROOT, options.out);
	fs.rmSync(consumerDir, { recursive: true, force: true });
	fs.mkdirSync(consumerDir, { recursive: true });

	fs.writeFileSync(
		path.join(consumerDir, "wally.toml"),
		[
			"[package]",
			'name = "krf-consumer/smoke"',
			'version = "0.0.0"',
			'registry = "https://github.com/UpliftGames/wally-index"',
			'realm = "shared"',
			"private = true",
			"",
			"[dependencies]",
			`KRF = "${manifest.name}@=${version}"`,
			"",
		].join("\n"),
	);
	fs.writeFileSync(
		path.join(consumerDir, "default.project.json"),
		`${JSON.stringify(
			{ name: "KRF-Consumer", tree: { $className: "DataModel", ReplicatedStorage: { Packages: { $path: "Packages" } } } },
			null,
			2,
		)}\n`,
	);

	const [scope, name] = manifest.name.split("/");
	const indexName = `${scope}_${name}@${version}`;

	if (source === "registry") {
		runChecked("wally", ["install"], { cwd: consumerDir });
		const lock = fs.readFileSync(path.join(consumerDir, "wally.lock"), "utf8");
		const resolved = lock
			.split("[[package]]")
			.some((entry) => entry.includes(`name = "${manifest.name}"`) && entry.includes(`version = "${version}"`));
		if (!resolved) throw new ReleaseError(`wally.lock does not resolve ${manifest.name}@${version}`);
	} else {
		if (version !== manifest.version) throw new ReleaseError("An archive consumer can only use the checked-out version");
		buildArchive();
		extract(ARCHIVE_PATH, path.join(consumerDir, "Packages", "_Index", indexName, name));
		fs.writeFileSync(
			path.join(consumerDir, "Packages", "KRF.lua"),
			`return require(script.Parent._Index["${indexName}"]["${name}"])\n`,
		);
	}

	const installed = path.join(consumerDir, "Packages", "_Index", indexName, name);
	for (const required of ["default.project.json", "src/init.luau", "src/server/init.luau", "src/client/init.luau"]) {
		if (!fs.existsSync(path.join(installed, required))) throw new ReleaseError(`Installed package is missing ${required}`);
	}

	const place = path.join(consumerDir, "consumer.rbxl");
	runChecked("rojo", ["build", path.join(consumerDir, "default.project.json"), "-o", place]);
	fs.copyFileSync(SMOKE_TASK, path.join(consumerDir, "Smoke.luau"));

	setOutput("place", path.relative(REPO_ROOT, place).split(path.sep).join("/"));
	writeSummary(`- Built a consumer of \`${manifest.name}@${version}\` installed from the ${source}\n`);
}

function listReleaseTags() {
	const tags = [];
	for (const tag of runChecked("git", ["tag", "--list", "v*"]).split(/\r?\n/).filter(Boolean)) {
		const parsed = parseReleaseTag(tag);
		if (!parsed.ok) continue;

		const sha = runChecked("git", ["rev-parse", `refs/tags/${tag}^{commit}`]).trim();
		const manifestText = run("git", ["show", `${sha}:wally.toml`]);
		let manifestVersion = null;
		if (manifestText.exitCode === 0) {
			try {
				manifestVersion = readPackageManifest(manifestText.stdout).version;
			} catch {
				manifestVersion = null;
			}
		}
		tags.push({ tag, version: parsed.version, sha, manifestVersion });
	}
	return tags;
}

function listVerifiedVersions() {
	const result = run("gh", ["release", "list", "--limit", "200", "--json", "tagName,isDraft"]);
	if (result.exitCode !== 0) throw new ReleaseError(`Could not list GitHub Releases: ${result.stderr.trim()}`);
	return new Set(
		JSON.parse(result.stdout)
			.filter((release) => !release.isDraft)
			.map((release) => parseReleaseTag(release.tagName))
			.filter((parsed) => parsed.ok)
			.map((parsed) => parsed.version),
	);
}

async function status() {
	const mainRef = run("git", ["rev-parse", "--verify", "origin/main"]).exitCode === 0 ? "origin/main" : "HEAD";
	const mainSha = runChecked("git", ["rev-parse", mainRef]).trim();
	const main = readPackageManifest(runChecked("git", ["show", `${mainSha}:wally.toml`]));

	const result = deriveReleaseStatus({
		tags: listReleaseTags(),
		main: { sha: mainSha, version: main.version },
		registry: await createRegistry().listVersions(main.name),
		verifiedVersions: listVerifiedVersions(),
	});

	writeSummary(renderReleaseStatus(result, main.version));

	for (const row of result.rows) {
		if (row.state !== STATES.verified && row.state !== STATES.candidate) {
			console.log(`::warning title=KRF release status::${row.subject}: ${row.state}`);
		}
	}
}

async function main(argv) {
	const [command, ...rest] = argv;
	const options = parseOptions(rest);

	switch (command) {
		case "bump":
			return bump(options);
		case "resolve":
			return resolve(options);
		case "preflight":
			return preflight(options);
		case "publish":
			return publish();
		case "verify-registry":
			return verifyRegistry(options);
		case "consumer":
			return prepareConsumer(options);
		case "status":
			return status();
		default:
			throw new ReleaseError(`Unknown command '${command ?? ""}'. Use bump, resolve, preflight, publish, verify-registry, consumer or status.`);
	}
}

if (require.main === module) {
	main(process.argv.slice(2)).catch((error) => {
		console.error(error instanceof ReleaseError ? error.message : error);
		process.exitCode = 1;
	});
}

module.exports = { main, ReleaseError };
