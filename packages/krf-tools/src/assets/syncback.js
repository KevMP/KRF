import fs from "node:fs";
import path from "node:path";

import { ExitCode, KrfToolError } from "../errors.js";
import { atLeast, readRojoVersion } from "../workflow/rojo.js";
import { placeOpenInStudio } from "../workflow/studio.js";
import { applyCapture, backUp, capturePaths, discardPlan, outsideCapture, planCapture, plannedFiles, readFiles } from "./capture.js";
import { findRepository, readWorkingTree } from "./git.js";
import { readCaptureScope, topLevelPaths } from "./scope.js";

export const MINIMUM_ROJO_VERSION = Object.freeze([7, 7, 1]);

const PLACE_EXTENSIONS = new Set([".rbxl", ".rbxlx"]);
const SHOWN_FILES = 20;

export function resolveInput(project, input) {
	const place = input === undefined ? project.place : path.resolve(project.root, input);
	const shown = path.relative(project.root, place).split(path.sep).join("/");
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

export function assertRojoSupportsSyncback(system, project) {
	const version = readRojoVersion(system, project);
	if (atLeast(version, MINIMUM_ROJO_VERSION)) return;
	const minimum = MINIMUM_ROJO_VERSION.join(".");
	throw new KrfToolError("RojoTooOld", `npm run assets:syncback needs Rojo ${minimum} or newer, but this project runs Rojo ${version.join(".")}.`, {
		hint: `Set rojo = "rojo-rbx/rojo@${minimum}" in rokit.toml, then run npm install.`,
	});
}

export function listed(label, files) {
	const shown = files.slice(0, SHOWN_FILES).map((file) => `  ${label === "" ? "" : `${label} `}${file}\n`);
	if (files.length > SHOWN_FILES) shown.push(`  ...and ${files.length - SHOWN_FILES} more\n`);
	return shown.join("");
}

export function assertInsideCapture(project, scope, plan) {
	const outside = outsideCapture(project, scope, plan);
	if (outside.length === 0) return;
	discardPlan(plan);
	throw new KrfToolError("OutsideCaptureScope", `Rojo would also change files outside the captured folders:\n${listed("", outside).trimEnd()}`, {
		hint: `Nothing was written. Map that content to a folder under world/, and list any code it holds in syncbackRules.ignoreTrees in ${scope.projectFile}.`,
	});
}

export function reportCapture(io, project, scope, plan, result) {
	const lines = [];
	if (plan.missing.length > 0) lines.push(`Not in the saved place, so left as they were: ${plan.missing.join(", ")}.\n`);
	if (result.declared.length > 0) {
		const values = result.declared.map((change) => `  ${change.tree}: ${change.names.join(", ")}\n`).join("");
		lines.push(
			result.declaredWritten
				? `Captured settings into ${scope.projectFile}:\n${values}`
				: `Not captured, because ${scope.projectFile} declares these instances; their values stay only in the place file:\n${values}${project.mode === "full" ? "" : `Set them in ${scope.projectFile} if they belong in source.\n`}`,
		);
	}
	const { created, changed, removed } = result.files;
	const total = created.length + changed.length + removed.length;
	lines.push(total === 0 ? "No changes: the captured folders already match the saved place.\n" : `Captured ${total} file change${total === 1 ? "" : "s"}:\n${listed("created", created)}${listed("changed", changed)}${listed("removed", removed)}`);
	io.stdout(lines.join(""));
	return total;
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

	const plan = planCapture(system, project, scope, input);
	assertInsideCapture(project, scope, plan);
	const files = plannedFiles(project, plan);

	if (options.dryRun) {
		discardPlan(plan);
		if (plan.missing.length > 0) io.stdout(`Not in the saved place, so they would be left as they are: ${plan.missing.join(", ")}.\n`);
		if (files.length < plan.planned.length) io.stdout(`Rojo would also update settings that ${scope.projectFile} declares.\n`);
		io.stdout(
			files.length === 0
				? "Nothing in the captured folders would change.\nNothing was written (--dry-run).\n"
				: `Rojo would rewrite or remove these files; a capture keeps any whose content does not change:\n${listed("", files.map((entry) => `${entry.action} ${entry.path}`)).trimEnd()}\nNothing was written (--dry-run).\n`,
		);
		return ExitCode.ok;
	}

	if (plan.planned.length === 0) {
		discardPlan(plan);
		if (plan.missing.length > 0) io.stdout(`Not in the saved place, so left as they were: ${plan.missing.join(", ")}.\n`);
		io.stdout("No changes: the captured folders already match the saved place.\n");
		return ExitCode.ok;
	}

	let guard;
	try {
		guard = guardWorkingTree(system, project, paths, options);
	} catch (error) {
		discardPlan(plan);
		throw error;
	}
	const before = readFiles(project, capturePaths(project, scope));
	const backup = guard.needsBackup ? backUp(project, plan, before) : undefined;

	let result;
	try {
		result = applyCapture(system, project, scope, input, plan, { before, backup });
	} catch (error) {
		if (backup === undefined) discardPlan(plan);
		else fs.rmSync(plan.file, { force: true });
		throw error;
	}

	const total = reportCapture(io, project, scope, plan, result);
	if (total === 0 || backup === undefined) discardPlan(plan);
	else fs.rmSync(plan.file, { force: true });
	if (total === 0) return ExitCode.ok;

	if (backup !== undefined) io.stdout(`The files as they were before this capture are in ${backup}.\n`);
	const reviewed = [...paths, ...(result.declaredWritten ? [scope.projectFile] : [])].join(" ");
	if (guard.git) {
		io.stdout(`Review with git status -- ${reviewed} and git diff -- ${reviewed}, then commit. Nothing was committed.\n`);
	} else {
		io.stdout("This project has no Git repository, so review the files listed above.\n");
	}
	io.stdout("Rebuild from source with npm run build to check the result.\n");
	return ExitCode.ok;
}
