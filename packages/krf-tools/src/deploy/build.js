import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { buildPlace, spawnTool } from "../workflow/tools.js";
import { resolvePlaceProject } from "../workflow/place-layout.js";
import { inspectPlace } from "./place.js";

export function sourceState(system, project) {
	const git = (...args) => {
		const result = spawnTool(system, "git", args, { cwd: project.root });
		if (result.status !== 0) throw new KrfToolError("git-source-unverified", "A Git checkout with at least one commit is required.");
		return result.stdout.trim();
	};
	const commit = git("rev-parse", "--verify", "HEAD");
	if (!/^[a-f0-9]{40}$/.test(commit) || git("rev-parse", "--show-prefix") !== "") {
		throw new KrfToolError("git-source-unverified", "Run cloud deployment from a committed KRF project at the Git repository root.");
	}
	return { commit, dirty: git("status", "--porcelain=v1", "--untracked-files=all") !== "" };
}

export function buildArtifact(system, project) {
	const npm = system.env.npm_execpath;
	if (!npm || !path.isAbsolute(npm)) throw new KrfToolError("npm-required", "Run this command through the project's npm scripts.");
	if (path.dirname(project.place) !== project.root) throw new KrfToolError("invalid-place-path", "Check the project name and build output in package.json.");
	const before = fs.lstatSync(project.place, { bigint: true, throwIfNoEntry: false });
	if (before && !before.isFile()) throw new KrfToolError("invalid-place-path", "The build output must be a regular .rbxl file.");
	const env = Object.fromEntries(Object.entries(system.env).filter(([name]) => !/^(?:KRF_ROBLOX_|KRF_GITHUB_TOKEN$)/i.test(name)));
	const result = spawnTool({ ...system, env }, process.execPath, [npm, "run", "build"], { cwd: project.root });
	if (result.status !== 0) throw new KrfToolError("place-build-failed", "npm run build failed. Run it directly to inspect the Rojo diagnostics.");
	const after = fs.lstatSync(project.place, { bigint: true, throwIfNoEntry: false });
	if (!after?.isFile() || (before?.ino === after.ino && before.mtimeNs === after.mtimeNs && before.ctimeNs === after.ctimeNs)) {
		throw new KrfToolError("place-build-missing", "npm run build did not create a fresh binary place at the project root.");
	}
	return inspectPlace(fs.readFileSync(project.place));
}

export function buildArtifacts(system, project, target) {
	if (!target.placeProjects) return new Map([["place", buildArtifact(system, project)]]);
	const projects = Object.entries(target.placeProjects).map(([name, file]) => [name, resolvePlaceProject(project.root, file)]);
	const output = path.join(project.root, "build", "places");
	fs.rmSync(output, { recursive: true, force: true });
	fs.mkdirSync(output, { recursive: true });
	const env = Object.fromEntries(Object.entries(system.env).filter(([name]) => !/^(?:KRF_ROBLOX_|KRF_GITHUB_TOKEN$)/i.test(name)));
	return new Map(projects.map(([name, projectFile]) => {
		const file = path.join(output, `${name}.rbxl`);
		buildPlace({ ...system, env }, project, projectFile, file);
		return [name, { ...inspectPlace(fs.readFileSync(file)), file }];
	}));
}
