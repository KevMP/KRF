import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { KrfToolError } from "../errors.js";
import { WORKFLOW_FOLDER } from "./project.js";

const STUDIO_PATH_HINT = "Pass the Roblox Studio executable with --studio-path <path>.";
const LAUNCH_CHECK_MS = 5000;

function existingFile(file) {
	try {
		return fs.statSync(file).isFile();
	} catch {
		return false;
	}
}

function registeredWindowsStudio(system) {
	const result = system.spawnSync("reg", ["query", "HKCR\\roblox-studio\\shell\\open\\command", "/ve"], { encoding: "utf8", windowsHide: true });
	if (result.status !== 0) return undefined;
	const command = /REG_SZ\s+(.+)$/m.exec(result.stdout ?? "")?.[1]?.trim();
	const executable = command === undefined ? undefined : (/^"([^"]+)"/.exec(command)?.[1] ?? /^(\S+\.exe)/i.exec(command)?.[1]);
	return executable !== undefined && existingFile(executable) ? executable : undefined;
}

function newestWindowsStudio(env) {
	const versions = path.join(env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"), "Roblox", "Versions");
	let entries;
	try {
		entries = fs.readdirSync(versions, { withFileTypes: true });
	} catch {
		return undefined;
	}
	return entries
		.filter((entry) => entry.isDirectory())
		.map((entry) => path.join(versions, entry.name, "RobloxStudioBeta.exe"))
		.filter(existingFile)
		.sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs)[0];
}

export function resolveStudio(system, explicit) {
	if (explicit !== undefined) {
		if (existingFile(explicit)) return path.resolve(explicit);
		throw new KrfToolError("StudioNotFound", `--studio-path ${explicit} is not a file.`, { hint: STUDIO_PATH_HINT });
	}

	const found =
		system.platform === "win32"
			? (registeredWindowsStudio(system) ?? newestWindowsStudio(system.env))
			: system.platform === "darwin"
				? ["/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio", path.join(os.homedir(), "Applications", "RobloxStudio.app", "Contents", "MacOS", "RobloxStudio")].find(existingFile)
				: undefined;

	if (found !== undefined) return found;
	if (system.platform !== "win32" && system.platform !== "darwin") {
		throw new KrfToolError("StudioUnsupported", `Roblox Studio does not run on ${system.platform}.`, { hint: "Run this command on Windows or macOS, or pass --studio-path." });
	}
	throw new KrfToolError("StudioNotFound", "Could not find Roblox Studio.", { hint: `Install Roblox Studio, or ${STUDIO_PATH_HINT.toLowerCase()}` });
}

export function placeOpenInStudio(system, place) {
	const lock = `${place}.lock`;
	if (!fs.existsSync(lock)) return false;
	if (system.platform !== "win32") return true;
	try {
		fs.closeSync(fs.openSync(lock, "r+"));
		return false;
	} catch (error) {
		return error.code === "EBUSY" || error.code === "EPERM";
	}
}

export function acquireStudioLock(root) {
	const file = path.join(root, ...WORKFLOW_FOLDER.split("/"), "studio.lock");
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const holder = Number.parseInt(fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "", 10);
	if (Number.isInteger(holder) && holder !== process.pid) {
		let alive = false;
		try {
			process.kill(holder, 0);
			alive = true;
		} catch (error) {
			alive = error.code === "EPERM";
		}
		if (alive) {
			throw new KrfToolError("StudioBusy", `Another KRF Studio run (process ${holder}) is using this project.`, { hint: "Wait for it to finish, then run the command again." });
		}
	}
	fs.writeFileSync(file, String(process.pid));
	return () => fs.rmSync(file, { force: true });
}

export function runStudioScript(system, { studio, place, script, output, timeoutSeconds }) {
	return new Promise((resolve) => {
		let settled = false;
		const finish = (state) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolve({ ...state, text: fs.existsSync(output) ? fs.readFileSync(output, "utf8") : "" });
		};

		const child = system.spawn(studio, ["--task", "RunScript", "--localPlaceFile", place, "--runScriptFile", script, "--outputFile", output, "--quitAfterExecution"], {
			stdio: "ignore",
			windowsHide: true,
		});
		const timer = setTimeout(() => {
			child.kill();
			finish({ exited: false, timedOut: true });
		}, timeoutSeconds * 1000);
		child.on("error", (error) => finish({ exited: false, timedOut: false, error }));
		child.on("exit", () => finish({ exited: true, timedOut: false }));
	});
}

export function openInStudio(system, studio, place) {
	return new Promise((resolve) => {
		let settled = false;
		const finish = (result) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolve(result);
		};

		const child = system.spawn(studio, ["--task", "EditFile", "--localPlaceFile", place], { detached: true, stdio: "ignore", windowsHide: false });
		const timer = setTimeout(() => {
			child.unref();
			finish({ ok: true, pid: child.pid });
		}, LAUNCH_CHECK_MS);
		child.on("error", (error) => finish({ ok: false, detail: error.message }));
		child.on("exit", (code) => finish(code === 0 ? { ok: true, pid: child.pid } : { ok: false, detail: `Roblox Studio exited with code ${code}` }));
	});
}

export function readMarker(text, name) {
	const match = new RegExp(`^__KRF_${name}__ (\\{[^\\r\\n]*\\})\\r?$`, "m").exec(text);
	if (match === null) return undefined;
	try {
		return JSON.parse(match[1]);
	} catch {
		return undefined;
	}
}

export function between(text, start, end) {
	const lines = text.split(/\r?\n/);
	const from = lines.findIndex((line) => line === start);
	const to = lines.findIndex((line, index) => index > from && line === end);
	return from === -1 ? [] : lines.slice(from + 1, to === -1 ? undefined : to);
}
