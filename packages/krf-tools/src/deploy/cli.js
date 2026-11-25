import fs from "node:fs";
import path from "node:path";
import { parseArgs, parseEnv } from "node:util";

import { ExitCode, KrfToolError, formatError } from "../errors.js";
import { readLocalProject } from "../workflow/project.js";
import { readPlaceLayout } from "../workflow/place-layout.js";
import { SYSTEM } from "../workflow/tools.js";
import { buildArtifacts, sourceState } from "./build.js";
import { keyName, namedPlaces, readCredential, readTargets, requireFull, selectTarget } from "./config.js";
import { githubClient } from "./github.js";
import { openCloud } from "./open-cloud.js";
import { publishPlaces, verifyPlaceTargets } from "./place-set.js";
import { openReleasePullRequest, tagRelease, verifyProductionSource } from "./release.js";
import { formatDeployment, progressLine } from "./report.js";

export const DEPLOY_SCRIPTS = Object.freeze(Object.fromEntries(
	["env:list", "deploy:dev", "open:dev", "deploy:qa", "deploy:prod", "release:pr", "release:tag"]
		.map((name) => [name, `krf-tools ${name}`]),
));
export const BUILD_PLACES_SCRIPT = "krf-tools build:places";

const FLAGS = {
	"env:list": [],
	"deploy:dev": ["developer", "verify-target", "allow-dirty"],
	"open:dev": ["developer", "place"],
	"deploy:qa": ["verify-target"],
	"deploy:prod": ["verify-target"],
	"release:pr": ["to"],
	"release:tag": [],
	"build:places": [],
};
export const DEPLOY_COMMANDS = Object.freeze(Object.keys(FLAGS));
const SUCCESS = new Set(["validated", "confirmed-published"]);
const BOOLEAN = new Set(["json", "help", "verify-target", "allow-dirty"]);
const DEFAULT_DEPENDENCIES = { system: SYSTEM, fetch: globalThis.fetch };
const LOCAL_DEV_SETTINGS = ["KRF_DEVELOPER", "KRF_ROBLOX_DEV_KEY"];

function developmentEnvironment(root, env) {
	const file = path.join(root, ".env");
	const stat = fs.lstatSync(file, { throwIfNoEntry: false });
	if (!stat?.isFile()) return env;
	const local = parseEnv(fs.readFileSync(file, "utf8"));
	return { ...Object.fromEntries(LOCAL_DEV_SETTINGS.filter((key) => local[key] !== undefined).map((key) => [key, local[key]])), ...env };
}

function readOptions(command, args) {
	const supported = [...FLAGS[command], "json", "help"];
	try {
		return parseArgs({
			args,
			options: Object.fromEntries(supported.map((flag) => [flag, { type: BOOLEAN.has(flag) ? "boolean" : "string" }])),
		}).values;
	} catch {
		throw new KrfToolError("invalid-deploy-options", `Check the available flags with npm run ${command} -- --help.`, { exitCode: ExitCode.usage });
	}
}

async function deployTarget(context, target, evidence, verifyOnly) {
	const { system, project, env, connect, notify } = context;
	notify("verify", target);
	const cloud = connect(readCredential(env, target));
	const ownershipVerification = await verifyPlaceTargets(cloud, target);
	await cloud.verifyPlaceKey(target);
	const verified = { ...evidence, target, mode: project.mode, ownershipVerification, keyScope: "verified-by-roblox" };
	if (verifyOnly) return { status: "validated", ...verified };
	notify("build", namedPlaces(target).map(([name]) => name));
	const artifacts = buildArtifacts(system, project, target);
	const after = sourceState(system, project);
	if (after.commit !== evidence.source.commit || (!evidence.source.dirty && after.dirty)) {
		throw new KrfToolError("source-changed", "The checked-out commit or working tree changed during the build.");
	}
	return publishPlaces(cloud, target, artifacts, verified, (name) => notify("publish", name));
}

function summarize(env, heading, target, record) {
	if (!env.GITHUB_STEP_SUMMARY || record.status !== "confirmed-published") return;
	const revisions = record.places ? Object.entries(record.places) : [["place", record]];
	const lines = revisions.map(([name, result]) => `- ${name}: place ${result.placeId ?? target.placeId}, revision ${result.revisionId}`);
	fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `${heading}\n\n${lines.join("\n")}\n`);
}

async function run(command, project, options, { system, fetch, cloudOptions }, notify) {
	const env = ["deploy:dev", "env:list", "open:dev"].includes(command)
		? developmentEnvironment(project.root, system.env)
		: system.env;
	if (command !== "env:list") requireFull(project);
	if (command === "build:places") {
		const artifacts = buildArtifacts(system, project, readPlaceLayout(project));
		return { status: "validated", places: Object.fromEntries([...artifacts].map(([name, artifact]) => [name, { placeSha256: artifact.placeSha256, file: artifact.file ?? project.place }])) };
	}
	if (command === "release:pr") return openReleasePullRequest(system, project, githubClient(env, fetch), options.to ?? "patch");
	if (command === "release:tag") return tagRelease(system, project, githubClient(env, fetch));

	const targets = readTargets(project);
	const developer = options.developer ?? env.KRF_DEVELOPER;
	if (command === "env:list") {
		return { status: "validated", mode: project.mode, developer, targets: targets.map((target) => ({
			...target, ownershipVerification: "unverified", credential: env[keyName(target.environment)]?.trim() ? "present" : "missing",
		})) };
	}
	const connect = (key) => openCloud(key, { ...cloudOptions, fetch });
	const context = { system, project, env, connect, notify };

	if (command === "open:dev" || command === "deploy:dev") {
		const target = selectTarget(targets, "dev", developer);
		if (command === "open:dev") {
			const place = new Map(namedPlaces(target)).get(options.place ?? target.startPlace ?? "place");
			if (!place) throw new KrfToolError("place-not-configured", "Choose a configured place name.");
			return { status: "validated", target: place, url: place.url ?? `https://www.roblox.com/games/${place.placeId}` };
		}
		const source = sourceState(system, project);
		if (source.dirty && !options["allow-dirty"] && !options["verify-target"]) {
			throw new KrfToolError("dirty-worktree", "You have uncommitted changes. Commit them, or publish them to your Dev universe anyway with npm run deploy:dev -- --allow-dirty.");
		}
		return deployTarget(context, target, { source }, options["verify-target"]);
	}

	if (command === "deploy:qa") {
		const target = selectTarget(targets, "qa");
		const source = sourceState(system, project);
		if (source.dirty) throw new KrfToolError("dirty-worktree", "Commit the working tree before deploying to QA.");
		const record = await deployTarget(context, target, { source, ref: env.GITHUB_REF_NAME }, options["verify-target"]);
		summarize(env, `QA publish confirmed for ${env.GITHUB_REF_NAME ?? source.commit}.`, target, record);
		return record;
	}

	const target = selectTarget(targets, "prod");
	const release = await verifyProductionSource(system, project, env, githubClient(env, fetch));
	const record = await deployTarget(context, target, { source: release.source, tag: release.tag }, options["verify-target"]);
	summarize(env, `Production publish confirmed for ${release.tag}.`, target, record);
	return record;
}

export async function runDeployment(argv, io, dependencies = DEFAULT_DEPENDENCIES) {
	const [command, ...args] = argv;
	const json = args.includes("--json");
	try {
		const options = readOptions(command, args);
		if (options.help) {
			io.stdout(`npm run ${command} -- ${[...FLAGS[command], "json"].map((flag) => `[--${flag}${BOOLEAN.has(flag) ? "" : " <value>"}]`).join(" ")}\n`);
			return ExitCode.ok;
		}
		const project = readLocalProject(io.cwd);
		const notify = json ? () => {} : (step, detail) => io.stdout(`${progressLine(step, detail)}\n`);
		const result = await run(command, project, options, dependencies, notify);
		if (json) io.stdout(`${JSON.stringify(result)}\n`);
		else if (command === "open:dev") io.stdout(`${result.url}\n`);
		else io.stdout(formatDeployment(command, options, result, project.root));
		return SUCCESS.has(result.status) ? ExitCode.ok : ExitCode.failure;
	} catch (error) {
		const expected = error instanceof KrfToolError;
		const result = { status: "failed", code: expected ? error.code : "deployment-error", message: expected ? error.message : "Could not finish the deployment command.", hint: expected ? error.hint : undefined };
		if (json) io.stdout(`${JSON.stringify(result)}\n`);
		else io.stderr(`${expected ? formatError(error) : result.message}\n`);
		return expected ? error.exitCode : ExitCode.failure;
	}
}
