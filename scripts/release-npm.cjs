#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const { ReleaseError, REPO_ROOT, parseOptions, run, runChecked, setOutput, writeSummary } = require("./release/cli.cjs");
const { checkNpmVersion, checkReleaseVersions, classifyRegistryLookup, decidePublish } = require("./release/npm.cjs");

const TOOLING = "@kevmp/krf-tools";
const CREATOR = "create-krf";
const PUBLISH_ORDER = [TOOLING, CREATOR];
const PACKAGE_DIRECTORIES = { [TOOLING]: "krf-tools", [CREATOR]: "create-krf" };
const TARBALL_LIST = "tarballs.json";
const SMOKE_PROJECT = "smoke";
const REGISTRY_ATTEMPTS = 20;
const REGISTRY_DELAY_MS = 15000;

function readManifest(name) {
	return JSON.parse(fs.readFileSync(path.join(REPO_ROOT, "packages", PACKAGE_DIRECTORIES[name], "package.json"), "utf8"));
}

function lookupVersion(name, version) {
	return classifyRegistryLookup(run("npm", ["view", `${name}@${version}`, "dist.integrity", "--json", "--prefer-online"]));
}

function readTarballs(directory) {
	const root = path.resolve(REPO_ROOT, directory);
	const listed = JSON.parse(fs.readFileSync(path.join(root, TARBALL_LIST), "utf8"));
	return PUBLISH_ORDER.map((name) => {
		const tarball = listed.find((entry) => entry.name === name);
		if (tarball === undefined) throw new ReleaseError(`${TARBALL_LIST} in ${root} has no ${name} tarball`);
		return { ...tarball, path: path.join(root, tarball.file), label: `${tarball.name}@${tarball.version}` };
	});
}

async function preflight() {
	const tooling = readManifest(TOOLING);
	const creator = readManifest(CREATOR);
	const versions = checkReleaseVersions({ tooling, creator });
	if (!versions.ok) throw new ReleaseError(versions.reason);

	const commit = runChecked("git", ["rev-parse", "HEAD"]).trim();
	runChecked("git", ["fetch", "--quiet", "origin", "main"]);
	if (run("git", ["merge-base", "--is-ancestor", commit, "FETCH_HEAD"]).exitCode !== 0) {
		throw new ReleaseError(`${commit} is not on main. Run the npm release from main.`);
	}

	const passed = JSON.parse(runChecked("gh", ["run", "list", "--workflow", "ci.yml", "--commit", commit, "--status", "success", "--json", "databaseId"]));
	if (passed.length === 0) throw new ReleaseError(`CI has not passed for ${commit}. Wait for it, then run the npm release again.`);

	const { KRF_RUNTIME } = await import(pathToFileURL(path.join(REPO_ROOT, "packages", PACKAGE_DIRECTORIES[TOOLING], "src", "compatibility.js")).href);
	if (run("gh", ["release", "view", `v${KRF_RUNTIME.version}`]).exitCode !== 0) {
		throw new ReleaseError(`${CREATOR} targets KRF ${KRF_RUNTIME.version}, which has no verified GitHub Release.`);
	}

	for (const manifest of [tooling, creator]) {
		const label = `${manifest.name}@${manifest.version}`;
		const lookup = lookupVersion(manifest.name, manifest.version);
		if (lookup.state === "present") throw new ReleaseError(`npm already has ${label}. Bump both package versions in a pull request first.`);
		if (lookup.state === "unknown") throw new ReleaseError(`Could not read ${label} from npm: ${lookup.detail}`);
	}

	setOutput("tooling_version", tooling.version);
	setOutput("creator_version", creator.version);
	writeSummary(`- ${TOOLING}@${tooling.version} and ${CREATOR}@${creator.version} are new on npm\n- CI passed for \`${commit}\`\n- ${CREATOR} targets KRF ${KRF_RUNTIME.version}\n`);
}

function pack(options) {
	if (options.out === undefined) throw new ReleaseError("pack requires --out <dir>");
	const out = path.resolve(REPO_ROOT, options.out);
	fs.rmSync(out, { recursive: true, force: true });
	fs.mkdirSync(out, { recursive: true });

	const packed = JSON.parse(runChecked("npm", ["pack", "--json", "--pack-destination", out, ...PUBLISH_ORDER.flatMap((name) => ["--workspace", name])]));
	const tarballs = packed.map((entry) => ({ name: entry.name, version: entry.version, file: entry.filename, integrity: entry.integrity }));
	fs.writeFileSync(path.join(out, TARBALL_LIST), `${JSON.stringify(tarballs, null, "\t")}\n`);
	writeSummary(tarballs.map((tarball) => `- Packed ${tarball.name}@${tarball.version} (\`${tarball.integrity}\`)`).join("\n") + "\n");
}

function publish(options) {
	if (options.from === undefined) throw new ReleaseError("publish requires --from <dir>");
	const npm = checkNpmVersion(runChecked("npm", ["--version"]).trim());
	if (!npm.ok) throw new ReleaseError(npm.reason);

	for (const tarball of readTarballs(options.from)) {
		const decision = decidePublish(tarball.label, lookupVersion(tarball.name, tarball.version), tarball.integrity);
		if (decision.action === "stop") throw new ReleaseError(decision.reason);
		if (decision.action === "skip") {
			writeSummary(`- ${tarball.label} is already on npm with the tested contents\n`);
			continue;
		}
		runChecked("npm", ["publish", tarball.path, "--access", "public"]);
		writeSummary(`- Published ${tarball.label}\n`);
	}
}

async function waitForVersion(tarball) {
	for (let attempt = 1; attempt <= REGISTRY_ATTEMPTS; attempt += 1) {
		const lookup = lookupVersion(tarball.name, tarball.version);
		if (lookup.state === "present") {
			if (lookup.integrity !== tarball.integrity) throw new ReleaseError(`npm serves ${tarball.label} with different contents than the tested tarball`);
			return;
		}
		await new Promise((resolve) => setTimeout(resolve, REGISTRY_DELAY_MS));
	}
	throw new ReleaseError(`npm did not serve ${tarball.label} after ${REGISTRY_ATTEMPTS} attempts`);
}

async function verifyPublished(tarballs) {
	for (const tarball of tarballs) await waitForVersion(tarball);

	const tooling = tarballs.find((tarball) => tarball.name === TOOLING);
	const creator = tarballs.find((tarball) => tarball.name === CREATOR);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "krf-npm-verify-"));
	const env = { ...process.env, npm_config_cache: path.join(root, "cache"), npm_config_audit: "false", npm_config_fund: "false" };

	runChecked("npx", ["--yes", `${CREATOR}@${creator.version}`, SMOKE_PROJECT, "--yes"], { cwd: root, env });
	const project = path.join(root, SMOKE_PROJECT);
	const dependency = JSON.parse(fs.readFileSync(path.join(project, "package.json"), "utf8")).devDependencies?.[TOOLING];
	if (dependency !== tooling.version) throw new ReleaseError(`The published creator wrote ${TOOLING} ${dependency ?? "nothing"} instead of ${tooling.version}`);

	runChecked("npm", ["install"], { cwd: project, env });
	runChecked("npm", ["run", "build"], { cwd: project, env });
	writeSummary(`- \`npx ${CREATOR}@${creator.version}\` created a project from a clean npm cache, and it installed and built\n`);
}

async function verify(options) {
	if (options.from === undefined) throw new ReleaseError("verify requires --from <dir>");
	const tarballs = readTarballs(options.from);
	try {
		await verifyPublished(tarballs);
	} catch (error) {
		const published = tarballs.map((tarball) => tarball.label).join(" and ");
		throw new ReleaseError(`${error.message}\n\nnpm accepted ${published}. Never republish them: fix the problem and release new versions.`);
	}
}

async function main(argv) {
	const [command, ...rest] = argv;
	const options = parseOptions(rest);

	switch (command) {
		case "preflight":
			return preflight();
		case "pack":
			return pack(options);
		case "publish":
			return publish(options);
		case "verify":
			return verify(options);
		default:
			throw new ReleaseError(`Unknown command '${command ?? ""}'. Use preflight, pack, publish or verify.`);
	}
}

if (require.main === module) {
	main(process.argv.slice(2)).catch((error) => {
		console.error(error instanceof ReleaseError ? `::error::${error.message.replaceAll("\n", "%0A")}` : error);
		process.exitCode = 1;
	});
}

module.exports = { main };
