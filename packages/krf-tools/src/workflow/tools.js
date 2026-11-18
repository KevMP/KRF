import { spawn, spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";

import { KrfToolError } from "../errors.js";

export function toolEnvironment(env = process.env) {
	const rokit = path.join(os.homedir(), ".rokit", "bin");
	const key = Object.keys(env).find((name) => name.toUpperCase() === "PATH") ?? "PATH";
	return { ...env, [key]: `${rokit}${path.delimiter}${env[key] ?? ""}` };
}

export const SYSTEM = Object.freeze({
	platform: process.platform,
	env: process.env,
	spawn,
	spawnSync,
	onInterrupt(handler) {
		process.on("SIGINT", handler);
		process.on("SIGTERM", handler);
		return () => {
			process.off("SIGINT", handler);
			process.off("SIGTERM", handler);
		};
	},
});

export function runTool(system, command, args, { cwd, quiet = false }) {
	const result = system.spawnSync(command, args, { cwd, env: toolEnvironment(system.env), encoding: "utf8", windowsHide: true });
	if (result.error?.code === "ENOENT") {
		throw new KrfToolError("ToolMissing", `${command} is not installed.`, { hint: "Run npm install in the project; it installs the tools pinned in rokit.toml." });
	}
	if (result.error) throw new KrfToolError("ToolFailed", `Could not run ${command}: ${result.error.message}`, { cause: result.error });
	if (result.status !== 0) {
		const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
		throw new KrfToolError("ToolFailed", `${command} ${args.join(" ")} failed${output ? `:\n${output}` : "."}`);
	}
	return quiet ? "" : `${result.stdout ?? ""}`;
}

export function buildPlace(system, project, projectFile, output) {
	runTool(system, "rojo", ["build", projectFile, "--output", output], { cwd: project.root });
	return output;
}
