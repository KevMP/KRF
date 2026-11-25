import fs from "node:fs";
import path from "node:path";

import { ExitCode } from "../errors.js";
import { runTool } from "./tools.js";

function rebaseFiles(node, from, to) {
	if (node.filePaths) {
		node.filePaths = node.filePaths.map((file) => path.relative(to, path.resolve(from, file)).split(path.sep).join("/"));
	}
	for (const child of node.children ?? []) rebaseFiles(child, from, to);
}

export function runSourcemap(system, project, _options, io) {
	const from = path.dirname(project.codeProject);
	const build = path.join(project.root, "build");
	fs.mkdirSync(build, { recursive: true });
	const temporary = fs.mkdtempSync(path.join(build, "krf-sourcemap-"));
	try {
		const file = path.join(temporary, "sourcemap.json");
		runTool(system, "rojo", ["sourcemap", project.codeProject, "--output", file, "--include-non-scripts"], { cwd: project.root });
		// Rojo paths are relative to the project file, but Wally and the analyzer read them from the repository root.
		const map = JSON.parse(fs.readFileSync(file, "utf8"));
		rebaseFiles(map, from, project.root);
		fs.writeFileSync(file, `${JSON.stringify(map)}\n`);
		fs.renameSync(file, path.join(project.root, "sourcemap.json"));
		io.stdout("Created sourcemap at sourcemap.json\n");
		return ExitCode.ok;
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}
