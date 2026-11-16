// Builds a project's complete file set, writes it in one step, then runs optional setup.
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	KrfToolError,
	PROJECT_METADATA_FILE,
	PROJECT_METADATA_VERSION,
	renderTemplates,
	serializeProjectMetadata,
	writeNewDirectory,
} from "krf-tools";

import { CREATOR_VERSION, KRF_RUNTIME, KRF_TOOLING, TEMPLATE_VERSION } from "./compatibility.js";

const TEMPLATES = fileURLToPath(new URL("../templates/", import.meta.url));

/**
 * Template directories applied in order. Optional features add files; none replace base files.
 * @param {import("./options.js").CreatorConfig} config
 */
export function templateRoots(config) {
	const roots = [path.join(TEMPLATES, "base")];
	if (config.options.ci) roots.push(path.join(TEMPLATES, "ci"));
	if (config.options.agents) roots.push(path.join(TEMPLATES, "agents"));
	return roots;
}

/** @param {import("./options.js").CreatorConfig} config */
export function projectMetadata(config) {
	return {
		metadataVersion: PROJECT_METADATA_VERSION,
		name: config.name,
		options: config.options,
		creator: { name: "create-krf", version: CREATOR_VERSION },
		template: { version: TEMPLATE_VERSION },
		runtime: { ...KRF_RUNTIME },
		tooling: { ...KRF_TOOLING },
	};
}

/** @param {import("./options.js").CreatorConfig} config */
function packageManifest(config) {
	const manifest = {
		name: config.name,
		version: "0.0.0",
		private: true,
		description: "A Roblox game built with KRF.",
		scripts: {
			"project:info": "krf-tools info",
		},
		devDependencies: {
			[KRF_TOOLING.package]: KRF_TOOLING.version,
		},
		engines: {
			node: ">=22.12.0",
		},
	};
	return `${JSON.stringify(manifest, null, 2)}\n`;
}

/**
 * Every file of the new project, keyed by relative POSIX path, in sorted order.
 * The same configuration and creator version always produce the same bytes.
 * @param {import("./options.js").CreatorConfig} config
 * @returns {Map<string, Buffer>}
 */
export function buildProjectFiles(config) {
	const metadata = projectMetadata(config);
	const rendered = renderTemplates(templateRoots(config), {
		name: config.name,
		options: config.options,
		runtime: metadata.runtime,
		tooling: metadata.tooling,
		creatorVersion: CREATOR_VERSION,
	});

	rendered.set("package.json", Buffer.from(packageManifest(config)));
	rendered.set(PROJECT_METADATA_FILE, Buffer.from(serializeProjectMetadata(metadata)));

	return new Map([...rendered.entries()].sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)));
}

/**
 * @typedef {(command: string, args: string[], options: { cwd: string }) => { status: number | null, stdout: string, stderr: string, error?: Error }} ProcessRunner
 */

/** @type {ProcessRunner} */
export function runProcess(command, args, options) {
	// npm is a .cmd shim on Windows, which Node only starts through a shell. Every caller passes
	// fixed arguments, so the command line is joined rather than built from user input.
	const result =
		process.platform === "win32"
			? spawnSync([command, ...args].join(" "), { cwd: options.cwd, encoding: "utf8", shell: true })
			: spawnSync(command, args, { cwd: options.cwd, encoding: "utf8" });
	return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "", error: result.error };
}

function insideGitWorkTree(directory, run) {
	const result = run("git", ["rev-parse", "--is-inside-work-tree"], { cwd: directory });
	return !result.error && result.status === 0 && result.stdout.trim() === "true";
}

/**
 * Creates the project. Files are written atomically before any setup step runs; a failed setup
 * step leaves the complete project in place and is reported as a setup problem.
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

	if (!config.install) {
		steps.push({ name: "install", status: "skipped", detail: "--skip-install" });
	} else {
		const result = run("npm", ["install", "--no-audit", "--no-fund"], { cwd: config.target });
		steps.push(
			result.error || result.status !== 0
				? { name: "install", status: "failed", detail: (result.error?.message ?? result.stderr).trim() || "npm install failed" }
				: { name: "install", status: "done" },
		);
	}

	return { files: [...files.keys()], steps };
}

/** Throws when a setup step failed after the project was written. */
export function assertSetupSucceeded(result, target) {
	const failed = result.steps.filter((step) => step.status === "failed");
	if (failed.length === 0) return;

	throw new KrfToolError(
		"SetupFailed",
		`Created ${target}, but ${failed.map((step) => `${step.name} failed: ${step.detail}`).join("; ")}`,
		{ hint: `The project files are complete. Fix the problem, then run the failed step inside ${target}.` },
	);
}
