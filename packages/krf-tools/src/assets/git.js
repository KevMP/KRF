import fs from "node:fs";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { spawnTool } from "../workflow/tools.js";

export function findRepository(root) {
	for (let directory = path.resolve(root); ; directory = path.dirname(directory)) {
		if (fs.existsSync(path.join(directory, ".git"))) return directory;
		if (path.dirname(directory) === directory) return undefined;
	}
}

export function readWorkingTree(system, root, paths) {
	let result;
	try {
		result = spawnTool(system, "git", ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--", ...paths], { cwd: root });
	} catch (error) {
		if (error instanceof KrfToolError) return { available: false, changed: [], ignored: [] };
		throw error;
	}
	if (result.status !== 0) return { available: false, changed: [], ignored: [] };

	const topLevel = spawnTool(system, "git", ["rev-parse", "--show-toplevel"], { cwd: root });
	const base = topLevel.status === 0 ? topLevel.stdout.trim() : root;
	const relative = (file) => path.relative(root, path.resolve(base, file)).split(path.sep).join("/");

	const changed = [];
	const ignored = [];
	const entries = (result.stdout ?? "").split("\0");
	for (let index = 0; index < entries.length; index += 1) {
		const entry = entries[index];
		if (entry.length < 4) continue;
		const status = entry.slice(0, 2);
		const file = relative(entry.slice(3));
		if (status[0] === "R" || status[0] === "C") index += 1;
		(status === "!!" ? ignored : changed).push(file);
	}
	return { available: true, changed: changed.sort(), ignored: ignored.sort() };
}
