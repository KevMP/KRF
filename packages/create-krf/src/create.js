import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { KRF_RUNTIME, KrfToolError, renderTemplates, writeNewDirectory } from "krf-tools";

import { CREATOR_VERSION, ROKIT_VERSION } from "./compatibility.js";
import { ROJO_PROJECT_FILE, generatedManifests } from "./manifests.js";

const TEMPLATES = fileURLToPath(new URL("../templates/", import.meta.url));

/** @param {import("./options.js").CreatorConfig} config */
export function templateRoots(config) {
	const roots = [path.join(TEMPLATES, "base")];
	if (config.options.mode === "full") roots.push(path.join(TEMPLATES, "full"));
	if (config.options.ci) roots.push(path.join(TEMPLATES, "ci"));
	if (config.options.ci && config.options.mode === "full") roots.push(path.join(TEMPLATES, "release"));
	return roots;
}

/**
 * @param {import("./options.js").CreatorConfig} config
 * @returns {Map<string, Buffer>}
 */
export function buildProjectFiles(config) {
	const places = config.options.places;
	const templates = renderTemplates(templateRoots(config), {
		name: config.name,
		options: config.options,
		runtime: KRF_RUNTIME,
		creatorVersion: CREATOR_VERSION,
		rokitVersion: ROKIT_VERSION,
		rojoProjectFile: ROJO_PROJECT_FILE,
	});
	const rendered = places === undefined ? templates : new Map([...templates].flatMap(([file, contents]) => (
		file.startsWith("world/") ? places.map((name) => [`world/${name}/${file.slice("world/".length)}`, contents]) : [[file, contents]]
	)));

	for (const [file, contents] of generatedManifests(config)) {
		if (rendered.has(file)) throw new Error(`Template and generated manifest both produce ${file}`);
		rendered.set(file, Buffer.from(contents));
	}

	return new Map([...rendered.entries()].sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)));
}

/**
 * @typedef {(command: string, args: string[], options: { cwd: string }) => { status: number | null, stdout: string, stderr: string, error?: Error }} ProcessRunner
 */

/** @type {ProcessRunner} */
export function runProcess(command, args, options) {
	const result = spawnSync(command, args, { cwd: options.cwd, encoding: "utf8" });
	return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "", error: result.error };
}

function insideGitWorkTree(directory, run) {
	const result = run("git", ["rev-parse", "--is-inside-work-tree"], { cwd: directory });
	return !result.error && result.status === 0 && result.stdout.trim() === "true";
}

/**
 * @param {import("./options.js").CreatorConfig} config
 * @param {{ run?: ProcessRunner }} [dependencies]
 * @returns {{ files: string[], steps: { name: string, status: "done" | "skipped" | "failed", detail?: string }[] }}
 */
export function createProject(config, dependencies = {}) {
	const run = dependencies.run ?? runProcess;
	const files = buildProjectFiles(config);
	writeNewDirectory(config.target, files);

	const steps = [];

	if (!config.git) {
		steps.push({ name: "git", status: "skipped", detail: "--no-git" });
	} else if (insideGitWorkTree(path.dirname(config.target), run)) {
		steps.push({ name: "git", status: "skipped", detail: "already inside a Git repository" });
	} else {
		const result = run("git", ["init", "--quiet"], { cwd: config.target });
		steps.push(
			result.error || result.status !== 0
				? { name: "git", status: "failed", detail: (result.error?.message ?? result.stderr).trim() || "git init failed" }
				: { name: "git", status: "done" },
		);
	}

	return { files: [...files.keys()], steps };
}

export function assertSetupSucceeded(result, target) {
	const failed = result.steps.filter((step) => step.status === "failed");
	if (failed.length === 0) return;

	throw new KrfToolError(
		"SetupFailed",
		`Created ${target}, but ${failed.map((step) => `${step.name} failed: ${step.detail}`).join("; ")}`,
		{ hint: `The project files are complete. Fix the problem, then run the failed step inside ${target}.` },
	);
}
