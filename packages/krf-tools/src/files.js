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

function lstatOrUndefined(target) {
	try {
		return fs.lstatSync(target);
	} catch (error) {
		if (error?.code === "ENOENT") return undefined;
		throw error;
	}
}

function assertNoLinks(root, relative) {
	let current = root;
	for (const segment of relative.split("/")) {
		current = path.join(current, segment);
		const stats = lstatOrUndefined(current);
		if (stats === undefined) return;
		if (stats.isSymbolicLink()) {
			throw new KrfToolError("UnsafeOutputPath", `Refusing to write through the link '${path.relative(root, current).split(path.sep).join("/")}'.`);
		}
	}
}

function fileChanged(relative) {
	return new KrfToolError("FileChanged", `${relative} changed while the generator was running.`, {
		hint: "Nothing was written. Run the command again.",
	});
}

export function applyProjectChanges(root, changes, options = {}) {
	const fileSystem = options.fileSystem ?? fs;
	const resolve = (relative) => path.join(root, ...relative.split("/"));

	for (const change of changes) {
		assertRelativeFile(change.path);
		assertNoLinks(root, change.path);
	}

	for (const change of changes) {
		const stats = lstatOrUndefined(resolve(change.path));
		if (change.kind === "create" && stats !== undefined) {
			throw new KrfToolError("FileExists", `${change.path} already exists.`, { hint: "Nothing was written." });
		}
		if (change.kind === "edit" && (stats === undefined || !fs.readFileSync(resolve(change.path)).equals(Buffer.from(change.before)))) {
			throw fileChanged(change.path);
		}
	}

	const createdFiles = [];
	const createdDirectories = [];
	const temporaryFiles = [];
	const editedFiles = [];

	try {
		for (const change of changes.filter((entry) => entry.kind === "create")) {
			const destination = resolve(change.path);
			const missing = [];
			for (let directory = path.dirname(destination); lstatOrUndefined(directory) === undefined; directory = path.dirname(directory)) {
				missing.unshift(directory);
			}
			for (const directory of missing) {
				fileSystem.mkdirSync(directory);
				createdDirectories.push(directory);
			}
			fileSystem.writeFileSync(destination, change.contents, { flag: "wx" });
			createdFiles.push(destination);
		}

		for (const change of changes.filter((entry) => entry.kind === "edit")) {
			const destination = resolve(change.path);
			const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.krf-${randomUUID().slice(0, 8)}`);
			fileSystem.writeFileSync(temporary, change.after, { flag: "wx" });
			temporaryFiles.push(temporary);

			if (!fs.readFileSync(destination).equals(Buffer.from(change.before))) throw fileChanged(change.path);
			fileSystem.renameSync(temporary, destination);
			temporaryFiles.pop();
			editedFiles.push({ destination, before: change.before });
		}
	} catch (error) {
		for (const { destination, before } of editedFiles.reverse()) fs.writeFileSync(destination, before);
		for (const temporary of temporaryFiles) fs.rmSync(temporary, { force: true });
		for (const file of createdFiles.reverse()) fs.rmSync(file, { force: true });
		for (const directory of createdDirectories.reverse()) {
			try {
				fs.rmdirSync(directory);
			} catch {
				break;
			}
		}
		if (error instanceof KrfToolError) throw error;
		throw new KrfToolError("WriteFailed", `Could not write the generated files: ${error.message}`, {
			cause: error,
			hint: "Every change was undone. Fix the cause and run the command again.",
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
