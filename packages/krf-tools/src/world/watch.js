import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { KrfToolError, formatError } from "../errors.js";
import { applyCapture, backUp, capturePaths, compareFiles, discardPlan, planCapture, readFiles } from "./capture.js";
import { findRepository, readWorkingTree } from "./git.js";
import { readCaptureScope, topLevelPaths } from "./scope.js";
import { assertInsideCapture, assertRojoSupportsSyncback, reportCapture } from "./syncback.js";

export const SAVE_SETTLE_MS = 1500;

const OFF = Object.freeze({ stop() {} });

const fileState = (file) => {
	try {
		return createHash("sha1").update(fs.readFileSync(file)).digest("hex");
	} catch {
		return undefined;
	}
};

function needsBackup(system, project, paths) {
	if (findRepository(project.root) === undefined) return true;
	const state = readWorkingTree(system, project.root, paths);
	return !state.available || state.changed.length > 0 || state.ignored.length > 0;
}

export function startAutoCapture(system, project, place, io, { settleMs = SAVE_SETTLE_MS, watch = fs.watch } = {}) {
	let scope;
	try {
		scope = readCaptureScope(project);
		assertRojoSupportsSyncback(system, project);
	} catch (error) {
		if (!(error instanceof KrfToolError)) throw error;
		io.stdout(`Saving in Studio does not capture the world: ${error.message}\n`);
		return OFF;
	}

	const input = { place, shown: path.relative(project.root, place).split(path.sep).join("/") };
	const paths = capturePaths(project, scope);
	let known = readFiles(project, paths);
	let firstCapture = true;
	let timer;
	let lastState = fileState(place);
	let stopped = false;

	const capture = () => {
		const current = readFiles(project, paths);
		const edited = compareFiles(known, current);
		const outside = [...edited.created, ...edited.changed, ...edited.removed];
		if (outside.length > 0) {
			known = current;
			io.stdout(`Studio saved ${input.shown}, but ${outside.length === 1 ? outside[0] : `${outside.length} captured files`} changed on disk since the last capture, so this save was not captured. If Studio is connected to Rojo it already has those changes; save again to capture.\n`);
			return;
		}

		const plan = planCapture(system, project, scope, input);
		assertInsideCapture(project, scope, plan);
		if (plan.planned.length === 0) {
			discardPlan(plan);
			io.stdout(`Studio saved ${input.shown}; nothing new to capture.\n`);
			return;
		}

		const backup = firstCapture && needsBackup(system, project, topLevelPaths(scope.roots)) ? backUp(project, plan, current) : undefined;
		firstCapture = false;
		io.stdout(`Studio saved ${input.shown}; capturing it.\n`);
		try {
			const result = applyCapture(system, project, scope, input, plan, { before: current, backup });
			reportCapture(io, project, scope, plan, result);
			if (backup !== undefined) io.stdout(`The files as they were before this session's first capture are in ${backup}.\n`);
		} finally {
			if (backup === undefined) discardPlan(plan);
			else fs.rmSync(plan.file, { force: true });
			known = readFiles(project, paths);
		}
	};

	const settle = () => {
		timer = undefined;
		if (stopped) return;
		const state = fileState(place);
		if (state === undefined || state === lastState) return;
		const settled = state;
		timer = setTimeout(() => {
			timer = undefined;
			if (stopped) return;
			if (fileState(place) !== settled) {
				schedule();
				return;
			}
			lastState = settled;
			try {
				capture();
			} catch (error) {
				io.stderr(`Capturing the save failed: ${formatError(error)}\n`);
			}
		}, Math.max(1, Math.floor(settleMs / 3)));
	};

	const schedule = () => {
		if (timer !== undefined) clearTimeout(timer);
		timer = setTimeout(settle, settleMs);
	};

	const watcher = watch(path.dirname(place), (event, file) => {
		if (file === null || file === undefined || path.basename(String(file)) === path.basename(place)) schedule();
	});
	io.stdout(`Saving ${input.shown} in Studio captures ${topLevelPaths(scope.roots).length === 1 ? topLevelPaths(scope.roots)[0] : "the mapped world folders"} automatically; npm run dev -- --no-syncback turns this off.\n`);

	return {
		stop() {
			stopped = true;
			if (timer !== undefined) clearTimeout(timer);
			watcher.close();
		},
	};
}
