import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "../errors.js";

export const RESERVED_FOLDERS = Object.freeze(["src", "tests", "Packages", "DevPackages", "ServerPackages", "node_modules", "build"]);

const HYBRID_OPT_IN = '"Workspace": { "$className": "Workspace", "Arenas": { "$path": "world/Workspace/Arenas" } }';

function readProjectFile(file) {
	let text;
	try {
		text = fs.readFileSync(file, "utf8");
	} catch (error) {
		throw new KrfToolError("ProjectFileUnreadable", `Could not read ${path.basename(file)}: ${error.message}`, { cause: error });
	}
	try {
		const project = JSON.parse(text);
		if (project === null || typeof project !== "object" || project.tree === null || typeof project.tree !== "object") throw new Error("it has no tree object");
		return project;
	} catch (error) {
		throw new KrfToolError("MalformedProject", `${path.basename(file)} is not a valid Rojo project: ${error.message}.`, {
			hint: "Fix the JSON, or restore the file from version control.",
			cause: error,
		});
	}
}

function ignoredTrees(project, file) {
	const rules = project.syncbackRules ?? {};
	const trees = rules.ignoreTrees ?? [];
	if (typeof rules !== "object" || !Array.isArray(trees) || trees.some((tree) => typeof tree !== "string" || tree === "")) {
		throw new KrfToolError("MalformedProject", `syncbackRules.ignoreTrees in ${file} must be a list of instance paths such as "ServerScriptService/Game".`);
	}
	return trees.map((tree) => tree.replace(/^\/+|\/+$/g, ""));
}

function mappedNodes(node, prefix = []) {
	const found = [];
	for (const [name, child] of Object.entries(node)) {
		if (name.startsWith("$") || child === null || typeof child !== "object" || Array.isArray(child)) continue;
		const tree = [...prefix, name];
		if (typeof child.$path === "string") found.push({ tree: tree.join("/"), path: child.$path });
		found.push(...mappedNodes(child, tree));
	}
	return found;
}

function nodeAt(tree, instancePath) {
	let node = tree;
	for (const name of instancePath.split("/")) {
		node = node?.[name];
		if (node === null || typeof node !== "object") return undefined;
	}
	return node;
}

function normalizeMapping(file, mapping) {
	const normalized = path.posix.normalize(mapping.path.replace(/\\/g, "/")).replace(/\/+$/, "");
	if (path.posix.isAbsolute(normalized) || path.win32.isAbsolute(mapping.path) || normalized === ".." || normalized.startsWith("../")) {
		throw new KrfToolError("MappingOutsideProject", `${mapping.tree} in ${file} maps ${mapping.path}, which is outside the project.`, {
			hint: "Captured content must live inside the project, for example under world/.",
		});
	}
	return normalized;
}

export function covers(paths, file) {
	return paths.some((root) => file === root || file.startsWith(`${root}/`));
}

export function topLevelPaths(roots) {
	const paths = [...new Set(roots.map((root) => root.path))].sort();
	return paths.filter((candidate) => !paths.some((other) => other !== candidate && candidate.startsWith(`${other}/`)));
}

export function readCaptureScope(project) {
	const file = path.basename(project.codeProject);
	const source = readProjectFile(project.codeProject);
	const ignored = ignoredTrees(source, file);
	const isIgnored = (tree) => ignored.some((entry) => tree === entry || tree.startsWith(`${entry}/`));

	const roots = [];
	for (const mapping of mappedNodes(source.tree)) {
		const normalized = normalizeMapping(file, mapping);
		const reserved = normalized === "." || RESERVED_FOLDERS.includes(normalized.split("/")[0]);
		if (isIgnored(mapping.tree)) continue;
		if (reserved) {
			throw new KrfToolError("UnprotectedMapping", `${mapping.tree} maps ${mapping.path}, which holds code or installed packages, but syncbackRules.ignoreTrees in ${file} does not list it.`, {
				hint: `Add "${mapping.tree}" to syncbackRules.ignoreTrees so a capture never rewrites it from the saved place.`,
			});
		}
		if (normalized.endsWith(".project.json")) {
			throw new KrfToolError("UnsupportedMapping", `${mapping.tree} maps the nested project ${mapping.path}; npm run assets:syncback captures only folders and model files.`, {
				hint: `Map the folder that holds the content instead, or add "${mapping.tree}" to syncbackRules.ignoreTrees.`,
			});
		}
		if (!fs.existsSync(path.join(project.root, ...normalized.split("/")))) {
			throw new KrfToolError("MappingMissing", `${mapping.tree} in ${file} maps ${normalized}, which does not exist.`, {
				hint: "Create it or restore it from version control. Put a .gitkeep file in a new folder so Git keeps it while it is empty.",
			});
		}
		roots.push(Object.freeze({ tree: mapping.tree, path: normalized }));
	}

	if (roots.length === 0) {
		throw new KrfToolError("NothingToCapture", `${file} maps no world content, so there is nothing to capture.`, {
			hint:
				project.mode === "hybrid"
					? `Opt a subtree in by adding ${HYBRID_OPT_IN} to ${file} and start-place.project.json, and create an empty world/Workspace/Arenas/.gitkeep.`
					: `Map Workspace to a folder, as new projects do: "Workspace": { "$className": "Workspace", "$ignoreUnknownInstances": true, "$path": "world/Workspace" }.`,
		});
	}

	if (project.mode === "hybrid") {
		const startFile = path.basename(project.placeProject);
		const start = readProjectFile(project.placeProject);
		for (const root of roots) {
			const node = nodeAt(start.tree, root.tree);
			const mapped = typeof node?.$path === "string" ? normalizeMapping(startFile, { tree: root.tree, path: node.$path }) : undefined;
			if (mapped !== root.path) {
				throw new KrfToolError("StartPlaceMappingMissing", `${root.tree} is captured into ${root.path}, but ${startFile} does not map it there.`, {
					hint: `Add the same "$path": "${root.path}" node to ${startFile}, so npm run build and new places include it.`,
				});
			}
		}
	}

	return Object.freeze({ projectFile: file, roots: Object.freeze(roots), ignored: Object.freeze(ignored) });
}
