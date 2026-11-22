import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { deriveProject, runDirectory } from "../workflow/project.js";
import { spawnTool } from "../workflow/tools.js";
import { declaredChanges, mergeDeclared } from "./declared.js";
import { normalizeCapture } from "./normalize.js";
import { covers, topLevelPaths } from "./scope.js";

const CAPTURE_PROJECT = "capture.project.json";
const JSON_MODEL_FILES = Object.freeze({ ROJO_SYNCBACK_DEBUG: "2" });
const LISTED = /^(Writing|Removing) (.+)$/;
const MISSING = /The child '([^']+)' of Instance '([^']+)' is present only in a project file/;
const ANSI = /\x1b\[[0-9;]*m/g;
const MAX_MISSING = 64;

const posix = (file) => file.split(path.sep).join("/");
const withoutCarriageReturns = (contents) => contents.toString("utf8").replace(/\r\n/g, "\n");
const sameContents = (left, right) => left.equals(right) || withoutCarriageReturns(left) === withoutCarriageReturns(right);

export function readFiles(project, paths) {
	const files = new Map();
	for (const relative of paths) {
		const absolute = path.join(project.root, ...relative.split("/"));
		let stats;
		try {
			stats = fs.lstatSync(absolute);
		} catch {
			continue;
		}
		if (stats.isFile()) {
			files.set(relative, fs.readFileSync(absolute));
			continue;
		}
		if (!stats.isDirectory()) continue;
		for (const entry of fs.readdirSync(absolute, { recursive: true, withFileTypes: true })) {
			if (!entry.isFile()) continue;
			const full = path.join(entry.parentPath, entry.name);
			files.set(posix(path.relative(project.root, full)), fs.readFileSync(full));
		}
	}
	return files;
}

export function compareFiles(before, after) {
	const created = [...after.keys()].filter((file) => !before.has(file));
	const removed = [...before.keys()].filter((file) => !after.has(file));
	const changed = [...after.keys()].filter((file) => before.has(file) && !sameContents(before.get(file), after.get(file)));
	return { created: created.sort(), changed: changed.sort(), removed: removed.sort() };
}

export function capturePaths(project, scope) {
	return [...topLevelPaths(scope.roots), scope.projectFile];
}

function failure(place, output) {
	const reason =
		output
			.split(/\r?\n/)
			.filter((line) => line.trim() !== "" && line !== "Beginning syncback..." && !/^\[WARN /.test(line))
			.join("\n")
			.replace(/^\[ERROR rojo\]\s*/, "") || "Rojo gave no reason.";
	const hint = /duplicated in the place file/.test(reason)
		? "Rename the duplicated instance in Studio so siblings under a mapped tree have unique names, save, and run the command again."
		: "Nothing was captured. Fix the cause and run the command again.";
	return new KrfToolError("SyncbackFailed", `rojo syncback could not capture ${place}:\n${reason}`, { hint });
}

function removeMissing(tree, rootName, child, parent) {
	const queue = [{ node: tree, name: rootName, path: [] }];
	while (queue.length > 0) {
		const current = queue.shift();
		for (const [name, node] of Object.entries(current.node)) {
			if (name.startsWith("$") || node === null || typeof node !== "object" || Array.isArray(node)) continue;
			if (name === child && current.name === parent) {
				delete current.node[name];
				return [...current.path, name].join("/");
			}
			queue.push({ node, name, path: [...current.path, name] });
		}
	}
	return undefined;
}

function runRojo(system, project, file, input, dryRun) {
	const args = ["syncback", file, "--input", input.place, "--non-interactive", "--color", "never", ...(dryRun ? ["--dry-run", "--list"] : [])];
	const result = spawnTool(system, "rojo", args, { cwd: project.root, env: JSON_MODEL_FILES });
	return { status: result.status, stdout: `${result.stdout ?? ""}`.replace(ANSI, ""), stderr: `${result.stderr ?? ""}`.replace(ANSI, "") };
}

function listedPaths(project, directory, stdout) {
	const planned = [];
	for (const line of stdout.split(/\r?\n/)) {
		const match = LISTED.exec(line.trim());
		if (match === null) continue;
		const printed = match[2].replace(/^\\\\\?\\/, "").replace(/\\/g, "/");
		planned.push({ action: match[1] === "Writing" ? "write" : "remove", path: posix(path.relative(project.root, path.resolve(directory, printed))) });
	}
	return planned;
}

export function planCapture(system, project, scope, input) {
	const directory = runDirectory(project, "syncback");
	const name = JSON.parse(fs.readFileSync(project.codeProject, "utf8")).name ?? project.name;
	const missing = [];
	let tree;
	const derive = () => deriveProject(project, directory, (derived) => {
		for (const removed of missing) removeMissing(derived, name, ...removed.key);
		tree = derived;
	}, project.codeProject, { fileName: CAPTURE_PROJECT, keep: ["syncbackRules"] });

	try {
		for (;;) {
			const file = derive();
			const result = runRojo(system, project, file, input, true);
			if (result.status === 0) {
				const planned = listedPaths(project, directory, result.stdout);
				return { directory, file, planned, missing: missing.map((entry) => entry.tree), before: fs.readFileSync(file) };
			}
			const match = MISSING.exec(result.stderr);
			if (match === null || missing.length >= MAX_MISSING) throw failure(input.shown, result.stderr);
			const probe = structuredClone(tree);
			const removed = removeMissing(probe, name, match[1], match[2]);
			if (removed === undefined) throw failure(input.shown, result.stderr);
			missing.push({ key: [match[1], match[2]], tree: removed });
		}
	} catch (error) {
		fs.rmSync(directory, { recursive: true, force: true });
		throw error;
	}
}

export function outsideCapture(project, scope, plan) {
	const captured = topLevelPaths(scope.roots);
	const derived = posix(path.relative(project.root, plan.file));
	return plan.planned.filter((entry) => entry.path !== derived && !covers(captured, entry.path)).map((entry) => entry.path);
}

export function plannedFiles(project, plan) {
	const derived = posix(path.relative(project.root, plan.file));
	return plan.planned.filter((entry) => entry.path !== derived);
}

export function backUp(project, plan, files) {
	const directory = path.join(plan.directory, "backup");
	fs.mkdirSync(directory, { recursive: true });
	for (const [relative, contents] of files) {
		const destination = path.join(directory, ...relative.split("/"));
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.writeFileSync(destination, contents);
	}
	return posix(path.relative(project.root, directory));
}

export function discardPlan(plan) {
	fs.rmSync(plan.directory, { recursive: true, force: true });
}

export function applyCapture(system, project, scope, input, plan, { before, backup }) {
	const paths = topLevelPaths(scope.roots);
	const result = runRojo(system, project, plan.file, input, false);
	if (result.status !== 0) {
		const error = failure(input.shown, result.stderr);
		const partial = compareFiles(before, readFiles(project, capturePaths(project, scope)));
		if (partial.created.length + partial.changed.length + partial.removed.length > 0) {
			error.hint = `${error.hint} Some files were already written${backup ? `; the previous files are in ${backup}` : "; restore them with git restore"}.`;
		}
		throw error;
	}

	const written = readFiles(project, paths);
	const rewritten = compareFiles(before, written);
	const normalized = normalizeCapture({ roots: scope.roots, before, after: written, changed: new Set([...rewritten.created, ...rewritten.changed]) });
	for (const [relative, contents] of normalized) {
		const previous = before.get(relative);
		const desired = previous !== undefined && withoutCarriageReturns(previous) === contents ? previous : Buffer.from(contents);
		if (!written.get(relative).equals(desired)) fs.writeFileSync(path.join(project.root, ...relative.split("/")), desired);
	}

	const captured = fs.readFileSync(plan.file, "utf8");
	const declared = declaredChanges(plan.before.toString("utf8"), captured);
	let declaredWritten = false;
	if (project.mode === "full" && declared.length > 0) {
		const projectFile = path.join(project.root, scope.projectFile);
		const merged = mergeDeclared(fs.readFileSync(projectFile, "utf8"), captured);
		if (merged !== undefined) {
			fs.writeFileSync(projectFile, merged);
			declaredWritten = true;
		}
	}

	const files = compareFiles(before, readFiles(project, capturePaths(project, scope)));
	return { files, declared, declaredWritten };
}
