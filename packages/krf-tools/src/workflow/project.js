import fs from "node:fs";
import path from "node:path";

import { ExitCode, KrfToolError } from "../errors.js";
import { findProjectRoot } from "../generate/consumer.js";
import { readPlaceLayout, resolvePlaceProject } from "./place-layout.js";

export const ROJO_PROJECT_FILE = "default.project.json";
export const HYBRID_START_PROJECT_FILE = "start-place.project.json";
export const TESTS_FOLDER = "tests";
export const WORKFLOW_FOLDER = "build/krf";

function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8"));
	} catch (error) {
		throw new KrfToolError("ProjectFileUnreadable", `Could not read ${file}: ${error.message}`, { cause: error });
	}
}

export function readLocalProject(cwd) {
	const root = findProjectRoot(cwd);
	const manifest = readJson(path.join(root, "package.json"));
	const startProject = path.join(root, HYBRID_START_PROJECT_FILE);
	const hybrid = fs.existsSync(startProject);
	const { startPlace, placeProjects } = hybrid ? {} : readPlaceLayout({ root }, manifest.krf ?? {});
	const projectFile = placeProjects ? resolvePlaceProject(root, placeProjects[startPlace]) : path.join(root, ROJO_PROJECT_FILE);
	if (!fs.existsSync(projectFile)) {
		throw new KrfToolError("RojoProjectMissing", `${ROJO_PROJECT_FILE} is missing from ${root}.`, {
			hint: "KRF projects map their source with default.project.json; restore it from version control.",
		});
	}

	const name = typeof manifest.name === "string" && manifest.name !== "" ? manifest.name : path.basename(root);
	return Object.freeze({
		root,
		name,
		mode: hybrid ? "hybrid" : "full",
		codeProject: projectFile,
		placeProject: hybrid ? startProject : projectFile,
		place: startPlace === undefined ? path.join(root, `${name}.rbxl`) : devPlaceFile(root, startPlace),
	});
}

function devPlaceFile(root, name) {
	return path.join(root, "build", "krf", "dev", `${name}.rbxl`);
}

export function projectForPlace(project, name, { placeProjects } = readPlaceLayout(project)) {
	if (project.mode !== "full" || !placeProjects) {
		throw new KrfToolError("InvalidOption", "--place requires a Full project with named places.", { exitCode: ExitCode.usage });
	}
	if (!Object.hasOwn(placeProjects, name)) {
		throw new KrfToolError("InvalidOption", `Unknown place "${name}". Available places are ${Object.keys(placeProjects).join(", ")}.`, { exitCode: ExitCode.usage });
	}
	const file = resolvePlaceProject(project.root, placeProjects[name]);
	return { ...project, codeProject: file, placeProject: file, place: devPlaceFile(project.root, name) };
}

function rebasePaths(node, from, to) {
	if (Array.isArray(node) || node === null || typeof node !== "object") return node;
	const copy = {};
	for (const [key, value] of Object.entries(node)) {
		copy[key] = key === "$path" && typeof value === "string" ? path.relative(to, path.resolve(from, value)).split(path.sep).join("/") : rebasePaths(value, from, to);
	}
	return copy;
}

export function deriveProject(project, directory, extend, source = project.codeProject, { fileName = "test.project.json", keep = [] } = {}) {
	const base = readJson(source);
	const tree = rebasePaths(base.tree, path.dirname(source), directory);
	extend(tree);
	const file = path.join(directory, fileName);
	const settings = Object.fromEntries(keep.filter((key) => base[key] !== undefined).map((key) => [key, base[key]]));
	fs.mkdirSync(directory, { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify({ name: base.name ?? project.name, tree, ...settings }, null, 2)}\n`);
	return file;
}

export function runDirectory(project, kind) {
	const stamp = new Date().toISOString().replace(/[:.]/g, "-");
	const directory = path.join(project.root, ...WORKFLOW_FOLDER.split("/"), `${kind}-${stamp}`);
	fs.mkdirSync(directory, { recursive: true });
	return directory;
}

export function service(tree, name) {
	tree[name] ??= { $className: name };
	return tree[name];
}
