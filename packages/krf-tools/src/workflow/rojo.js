import net from "node:net";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { runTool, toolEnvironment } from "./tools.js";

export const DEFAULT_ROJO_PORT = 34872;
const READY = /Port:\s*(\d+)/;
const ANSI = /\x1b\[[0-9;]*m/g;
const VERSION = /(\d+)\.(\d+)\.(\d+)/;

export function readRojoVersion(system, project) {
	const output = runTool(system, "rojo", ["--version"], { cwd: project.root });
	const match = VERSION.exec(output);
	if (match === null) throw new KrfToolError("RojoVersionUnknown", `Could not read the Rojo version from: ${output.trim() || "no output"}.`);
	return match.slice(1).map(Number);
}

export function atLeast(version, minimum) {
	for (let index = 0; index < minimum.length; index += 1) {
		if (version[index] !== minimum[index]) return version[index] > minimum[index];
	}
	return true;
}

export function portAvailable(port) {
	return new Promise((resolve) => {
		const server = net.createServer();
		server.once("error", () => resolve(false));
		server.once("listening", () => server.close(() => resolve(true)));
		server.listen(port, "127.0.0.1");
	});
}

export async function assertPortAvailable(port, explicit) {
	if (await portAvailable(port)) return;
	throw new KrfToolError("RojoPortInUse", `Port ${port} is already in use, possibly by another rojo serve.`, {
		hint: explicit ? "Choose a free port with --port <port>." : `Stop the other Rojo server, or serve on another port with npm run dev -- --port ${port + 1}.`,
	});
}

export function startRojoServe(system, project, projectFile, port) {
	const child = system.spawn("rojo", ["serve", path.relative(project.root, projectFile), "--port", String(port)], {
		cwd: project.root,
		env: toolEnvironment(system.env),
		stdio: ["ignore", "pipe", "pipe"],
		windowsHide: true,
	});

	const ready = new Promise((resolve, reject) => {
		let output = "";
		const collect = (chunk) => {
			output += chunk.toString().replace(ANSI, "");
			const match = READY.exec(output);
			if (match !== null) {
				child.stdout.removeListener("data", collect);
				child.stderr.removeListener("data", collect);
				resolve(Number(match[1]));
			}
		};
		child.stdout.on("data", collect);
		child.stderr.on("data", collect);
		child.once("error", (error) => {
			reject(
				error.code === "ENOENT"
					? new KrfToolError("ToolMissing", "rojo is not installed.", { hint: "Run npm install in the project; it installs the tools pinned in rokit.toml." })
					: new KrfToolError("RojoServeFailed", `Could not start rojo serve: ${error.message}`, { cause: error }),
			);
		});
		child.once("exit", (code) => reject(new KrfToolError("RojoServeFailed", `rojo serve exited with code ${code} before it was ready.${output.trim() ? `\n${output.trim()}` : ""}`)));
	});

	const exited = new Promise((resolve) => child.once("exit", (code) => resolve(code)));
	return { child, ready, exited };
}
