// Creates a new directory from a complete in-memory file set without partial results.
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "./errors.js";

/**
 * Confirms `target` can become a new project: it must not exist, or be an empty directory.
 * @param {string} target Absolute path.
 * @returns {{ exists: boolean }}
 */
export function inspectTarget(target) {
	let stats;
	try {
		stats = fs.statSync(target);
	} catch (error) {
		if (error?.code === "ENOENT") return { exists: false };
		throw error;
	}

	if (!stats.isDirectory()) {
		throw new KrfToolError("TargetNotDirectory", `${target} already exists and is not a directory.`, {
			hint: "Choose another project name or location.",
		});
	}

	if (fs.readdirSync(target).length > 0) {
		throw new KrfToolError("TargetNotEmpty", `${target} already exists and is not empty.`, {
			hint: "Choose another project name, or create the project in an empty directory.",
		});
	}

	return { exists: true };
}

function assertRelativeFile(relative) {
	const normalized = path.posix.normalize(relative);
	if (relative === "" || path.posix.isAbsolute(relative) || path.win32.isAbsolute(relative) || normalized.startsWith("../") || normalized !== relative) {
		throw new KrfToolError("UnsafeOutputPath", `Refusing to write outside the project: '${relative}'.`);
	}
}

/**
 * Writes `files` as the new directory `target`. Files are first written to a hidden staging
 * directory beside the target and then renamed into place, so the project appears complete or
 * not at all. A failure removes only the staging directory and any parent directories this call
 * created; existing content is never deleted.
 * @param {string} target Absolute path.
 * @param {Map<string, Buffer | string>} files Relative POSIX path to contents.
 * @param {{ fileSystem?: Pick<typeof fs, "mkdirSync" | "writeFileSync" | "renameSync" | "rmdirSync" | "rmSync"> }} [options]
 */
export function writeNewDirectory(target, files, options = {}) {
	const fileSystem = options.fileSystem ?? fs;
	for (const relative of files.keys()) assertRelativeFile(relative);

	const { exists } = inspectTarget(target);
	const parent = path.dirname(target);
	const createdParent = firstMissingAncestor(parent);
	if (createdParent) fileSystem.mkdirSync(parent, { recursive: true });
	const staging = path.join(parent, `.${path.basename(target)}.krf-${randomUUID().slice(0, 8)}`);

	try {
		fileSystem.mkdirSync(staging);
		for (const [relative, contents] of files) {
			const destination = path.join(staging, ...relative.split("/"));
			fileSystem.mkdirSync(path.dirname(destination), { recursive: true });
			fileSystem.writeFileSync(destination, contents, { flag: "wx" });
		}

		inspectTarget(target);
		if (exists) fileSystem.rmdirSync(target);
		fileSystem.renameSync(staging, target);
	} catch (error) {
		fs.rmSync(staging, { recursive: true, force: true });
		if (createdParent) removeEmptyDirectories(createdParent, parent);
		if (error instanceof KrfToolError) throw error;
		throw new KrfToolError("WriteFailed", `Could not create ${target}: ${error.message}`, {
			cause: error,
			hint: "No files were left behind. Fix the cause and run the command again.",
		});
	}
}

/** The highest directory on the way to `directory` that does not exist yet, or null. */
function firstMissingAncestor(directory) {
	let missing = null;
	let current = directory;
	while (!fs.existsSync(current)) {
		missing = current;
		const next = path.dirname(current);
		if (next === current) break;
		current = next;
	}
	return missing;
}

function removeEmptyDirectories(topmost, deepest) {
	let current = deepest;
	while (current.length >= topmost.length) {
		try {
			fs.rmdirSync(current);
		} catch {
			return;
		}
		if (current === topmost) return;
		current = path.dirname(current);
	}
}
