import fs from "node:fs";
import path from "node:path";

import { ExitCode, KrfToolError } from "../errors.js";
import { runDirectory } from "../workflow/project.js";
import { atLeast, readRojoVersion } from "../workflow/rojo.js";
import { placeOpenInStudio } from "../workflow/studio.js";
import { spawnTool } from "../workflow/tools.js";
import { findRepository, readWorkingTree } from "./git.js";
import { normalizeCapture } from "./normalize.js";
import { covers, declaredChanges, readCaptureScope, topLevelPaths } from "./scope.js";

export const MINIMUM_ROJO_VERSION = Object.freeze([7, 7, 1]);

const PLACE_EXTENSIONS = new Set([".rbxl", ".rbxlx"]);
const JSON_MODEL_FILES = Object.freeze({ ROJO_SYNCBACK_DEBUG: "2" });
const LISTED = /^(Writing|Removing) (.+)$/;
const ANSI = /\x1b\[[0-9;]*m/g;
const SHOWN_FILES = 20;

const posix = (file) => file.split(path.sep).join("/");
const withoutCarriageReturns = (contents) => contents.toString("utf8").replace(/\r\n/g, "\n");
const sameContents = (left, right) => left.equals(right) || withoutCarriageReturns(left) === withoutCarriageReturns(right);

function resolveInput(project, input) {
	const place = input === undefined ? project.place : path.resolve(project.root, input);
	const shown = posix(path.relative(project.root, place));
	if (!PLACE_EXTENSIONS.has(path.extname(place).toLowerCase())) {
		throw new KrfToolError("InvalidInput", `--input ${input} is not a place file.`, { hint: "Pass the .rbxl or .rbxlx file you saved from Roblox Studio.", exitCode: ExitCode.usage });
	}
	let stats;
	try {
		stats = fs.statSync(place);
	} catch {
		throw new KrfToolError("PlaceMissing", `${shown} does not exist.`, {
			hint: input === undefined ? "Save the place in Roblox Studio first, or pass the saved file with --input <place.rbxl>." : "Check the path, then save the place from Roblox Studio to it.",
		});
	}
	if (!stats.isFile()) throw new KrfToolError("InvalidInput", `${shown} is not a file.`, { hint: "Pass the .rbxl or .rbxlx file you saved from Roblox Studio.", exitCode: ExitCode.usage });
	return { place, shown };
}

function assertRojoSupportsSyncback(system, project) {
	const version = readRojoVersion(system, project);
	if (atLeast(version, MINIMUM_ROJO_VERSION)) return;
	const minimum = MINIMUM_ROJO_VERSION.join(".");
	throw new KrfToolError("RojoTooOld", `npm run assets:syncback needs Rojo ${minimum} or newer, but this project runs Rojo ${version.join(".")}.`, {
		hint: `Set rojo = "rojo-rbx/rojo@${minimum}" in rokit.toml, then run npm install.`,
	});
}

function readFiles(project, paths) {
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

function syncbackFailure(place, output) {
	const reason =
		output
			.split(/\r?\n/)
			.filter((line) => line.trim() !== "" && line !== "Beginning syncback...")
			.join("\n")
			.replace(/^\[ERROR rojo\]\s*/, "") || "Rojo gave no reason.";
	const hint = /duplicated in the place file/.test(reason)
		? "Rename the duplicated instance in Studio so siblings under a mapped tree have unique names, save, and run the command again."
		: /present only in a project file/.test(reason)
			? "The saved place lacks an instance the project declares. Check that --input is this game's place, or run npm run dev once so Rojo creates it, then save again."
			: "Nothing was captured. Fix the cause and run the command again.";
	return new KrfToolError("SyncbackFailed", `rojo syncback could not capture ${place}:\n${reason}`, { hint });
}

function runRojoSyncback(system, project, scope, input, dryRun) {
	const args = ["syncback", scope.projectFile, "--input", input.place, "--non-interactive", "--color", "never", ...(dryRun ? ["--dry-run", "--list"] : [])];
	const result = spawnTool(system, "rojo", args, { cwd: project.root, env: JSON_MODEL_FILES });
	const stderr = `${result.stderr ?? ""}`.replace(ANSI, "");
	if (result.status !== 0) throw syncbackFailure(input.shown, stderr);

	const planned = [];
	for (const line of `${result.stdout ?? ""}`.replace(ANSI, "").split(/\r?\n/)) {
		const match = LISTED.exec(line.trim());
		if (match !== null) planned.push({ action: match[1] === "Writing" ? "write" : "remove", path: match[2].replace(/\\/g, "/").replace(/^\.\//, "") });
	}
	return planned;
}

function keepProjectFile(project, scope, run) {
	const file = path.join(project.root, scope.projectFile);
	const original = fs.readFileSync(file);
	let written;
	try {
		run();
	} finally {
		written = fs.readFileSync(file);
		if (!written.equals(original)) fs.writeFileSync(file, original);
	}
	return written.equals(original) ? [] : declaredChanges(original.toString("utf8"), written.toString("utf8"));
}

function reportDeclared(io, scope, changes) {
	if (changes.length === 0) return;
	const lines = changes.map((change) => `  ${change.tree}: ${change.names.join(", ")}\n`).join("");
	io.stdout(`Not captured, because ${scope.projectFile} declares these instances; their values stay only in the place file:\n${lines}Set them in ${scope.projectFile} if they belong in source.\n`);
}

function compare(before, after) {
	const created = [...after.keys()].filter((file) => !before.has(file));
	const removed = [...before.keys()].filter((file) => !after.has(file));
	const changed = [...after.keys()].filter((file) => before.has(file) && !sameContents(before.get(file), after.get(file)));
	return { created: created.sort(), changed: changed.sort(), removed: removed.sort() };
}

function listed(label, files) {
	const shown = files.slice(0, SHOWN_FILES).map((file) => `  ${label === "" ? "" : `${label} `}${file}\n`);
	if (files.length > SHOWN_FILES) shown.push(`  ...and ${files.length - SHOWN_FILES} more\n`);
	return shown.join("");
}

function backUp(project, files) {
	const directory = path.join(runDirectory(project, "syncback"), "backup");
	fs.mkdirSync(directory, { recursive: true });
	for (const [relative, contents] of files) {
		const destination = path.join(directory, ...relative.split("/"));
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.writeFileSync(destination, contents);
	}
	return posix(path.relative(project.root, directory));
}

function guardWorkingTree(system, project, paths, options) {
	if (findRepository(project.root) === undefined) return { git: false, needsBackup: true };
	const state = readWorkingTree(system, project.root, paths);
	if (!state.available) return { git: false, needsBackup: true };
	if (state.changed.length > 0 && !options.allowDirty) {
		throw new KrfToolError("UncommittedChanges", `The captured folders have uncommitted changes, so a capture could overwrite them:\n${listed("", state.changed).trimEnd()}`, {
			hint: "Commit or stash them, then run the command again. To capture anyway, pass --allow-dirty; the current files are copied to build/krf first.",
		});
	}
	return { git: true, needsBackup: state.changed.length > 0 || state.ignored.length > 0 };
}

export async function runSyncback(system, project, options, io) {
	const input = resolveInput(project, options.input);
	assertRojoSupportsSyncback(system, project);
	const scope = readCaptureScope(project);
	const paths = topLevelPaths(scope.roots);

	io.stdout(`Capturing ${input.shown} into ${scope.projectFile} (${project.mode === "hybrid" ? "Hybrid" : "Full"} project).\n`);
	io.stdout(`Captured trees:\n${scope.roots.map((root) => `  ${root.tree} -> ${root.path}\n`).join("")}`);
	if (scope.ignored.length > 0) io.stdout(`Never captured: ${scope.ignored.join(", ")}.\n`);
	io.stdout("Anything else in the place stays only in the place file.\n");
	if (placeOpenInStudio(system, input.place)) io.stdout(`Roblox Studio has ${input.shown} open; this captures its last save.\n`);

	const planned = runRojoSyncback(system, project, scope, input, true);
	const outside = planned.filter((entry) => entry.path !== scope.projectFile && !covers(paths, entry.path)).map((entry) => entry.path);
	if (outside.length > 0) {
		throw new KrfToolError("OutsideCaptureScope", `Rojo would also change files outside the captured folders:\n${listed("", outside).trimEnd()}`, {
			hint: `Nothing was written. Map that content to a folder under world/, and list any code it holds in syncbackRules.ignoreTrees in ${scope.projectFile}.`,
		});
	}
	const files = planned.filter((entry) => entry.path !== scope.projectFile);

	if (planned.length === 0) {
		io.stdout("No changes: the captured folders already match the saved place.\n");
		return ExitCode.ok;
	}

	if (options.dryRun) {
		if (files.length < planned.length) io.stdout(`${scope.projectFile} would be kept as it is; a capture lists the declared values it leaves in the place.\n`);
		if (files.length === 0) {
			io.stdout("Nothing in the captured folders would change.\nNothing was written (--dry-run).\n");
			return ExitCode.ok;
		}
		io.stdout(`Rojo would rewrite or remove these files; a capture keeps any whose content does not change:\n${listed("", files.map((entry) => `${entry.action === "write" ? "write" : "remove"} ${entry.path}`)).trimEnd()}\nNothing was written (--dry-run).\n`);
		return ExitCode.ok;
	}

	const guard = guardWorkingTree(system, project, paths, options);
	const before = readFiles(project, paths);
	const backup = guard.needsBackup ? backUp(project, before) : undefined;

	let declared = [];
	try {
		declared = keepProjectFile(project, scope, () => runRojoSyncback(system, project, scope, input, false));
	} catch (error) {
		const partial = compare(before, readFiles(project, paths));
		if (partial.created.length + partial.changed.length + partial.removed.length > 0 && error instanceof KrfToolError) {
			error.hint = `${error.hint} Some files were already written${backup ? `; the previous files are in ${backup}` : "; restore them with git restore"}.`;
		}
		throw error;
	}

	const written = readFiles(project, paths);
	const rewritten = compare(before, written);
	const normalized = normalizeCapture({ roots: scope.roots, before, after: written, changed: new Set([...rewritten.created, ...rewritten.changed]) });
	for (const [relative, contents] of normalized) {
		const previous = before.get(relative);
		const desired = previous !== undefined && withoutCarriageReturns(previous) === contents ? previous : Buffer.from(contents);
		if (!written.get(relative).equals(desired)) fs.writeFileSync(path.join(project.root, ...relative.split("/")), desired);
	}

	const result = compare(before, readFiles(project, paths));
	const total = result.created.length + result.changed.length + result.removed.length;
	if (total === 0) {
		if (backup !== undefined) fs.rmSync(path.dirname(path.join(project.root, ...backup.split("/"))), { recursive: true, force: true });
		reportDeclared(io, scope, declared);
		io.stdout("No changes: the captured folders already match the saved place.\n");
		return ExitCode.ok;
	}

	io.stdout(`Captured ${total} file change${total === 1 ? "" : "s"}:\n${listed("created", result.created)}${listed("changed", result.changed)}${listed("removed", result.removed)}`);
	reportDeclared(io, scope, declared);
	if (backup !== undefined) io.stdout(`The files as they were before this capture are in ${backup}.\n`);
	if (guard.git) {
		io.stdout(`Review with git status -- ${paths.join(" ")} and git diff -- ${paths.join(" ")}, then commit. Nothing was committed.\n`);
	} else {
		io.stdout("This project has no Git repository, so review the files listed above.\n");
	}
	io.stdout("Rebuild from source with npm run build to check the result.\n");
	return ExitCode.ok;
}
