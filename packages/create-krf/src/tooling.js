import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TOOLS_PACKAGE, TOOLS_VERSION } from "krf-tools";

function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8"));
	} catch {
		return undefined;
	}
}

export function toolsDependency(packageDirectory) {
	const segments = path.resolve(packageDirectory).split(path.sep);

	for (let index = segments.lastIndexOf("node_modules"); index !== -1; index = segments.lastIndexOf("node_modules", index - 1)) {
		const root = segments.slice(0, index).join(path.sep);
		const key = segments.slice(index).join("/");
		for (const lockfile of [path.join(root, "node_modules", ".package-lock.json"), path.join(root, "package-lock.json")]) {
			const resolved = readJson(lockfile)?.packages?.[key]?.resolved;
			if (typeof resolved === "string" && resolved.startsWith("file:") && resolved.endsWith(".tgz")) {
				return `file:${path.resolve(root, resolved.slice("file:".length)).split(path.sep).join("/")}`;
			}
		}
		if (index === 0) break;
	}

	return TOOLS_VERSION;
}

export const TOOLS_DEPENDENCY = Object.freeze({
	[TOOLS_PACKAGE]: toolsDependency(path.dirname(path.dirname(fileURLToPath(import.meta.resolve(TOOLS_PACKAGE))))),
});
