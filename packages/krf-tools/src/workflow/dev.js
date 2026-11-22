import fs from "node:fs";
import path from "node:path";

import { startAutoCapture } from "../assets/watch.js";
import { ExitCode, KrfToolError } from "../errors.js";
import { HYBRID_START_PROJECT_FILE, ROJO_PROJECT_FILE } from "./project.js";
import { DEFAULT_ROJO_PORT, assertPortAvailable, startRojoServe } from "./rojo.js";
import { openInStudio, placeOpenInStudio, resolveStudio } from "./studio.js";
import { buildPlace } from "./tools.js";

function relative(project, file) {
	return path.relative(project.root, file).split(path.sep).join("/");
}

function preparePlace(system, project, options, io) {
	if (project.mode === "full") {
		if (options.place !== undefined) throw new KrfToolError("InvalidOption", "--place applies only to Hybrid projects; Full projects build their place from source.", { exitCode: ExitCode.usage });
		if (placeOpenInStudio(system, project.place)) {
			io.stdout(`Roblox Studio already has ${relative(project, project.place)} open, so it was not rebuilt.\n`);
			return { place: project.place, open: false };
		}
		buildPlace(system, project, project.placeProject, project.place);
		io.stdout(`Built ${relative(project, project.place)} from ${ROJO_PROJECT_FILE}.\n`);
		return { place: project.place, open: true };
	}

	const place = options.place === undefined ? project.place : path.resolve(project.root, options.place);
	if (placeOpenInStudio(system, place)) {
		io.stdout(`Roblox Studio already has ${relative(project, place)} open.\n`);
		return { place, open: false };
	}
	if (fs.existsSync(place)) {
		io.stdout(`Using your Studio place ${relative(project, place)}; npm run dev never rebuilds it.\n`);
		return { place, open: true };
	}
	if (options.place !== undefined) {
		throw new KrfToolError("PlaceMissing", `${relative(project, place)} does not exist.`, { hint: "Pass the .rbxl file that holds your world, or omit --place to create one from the starter world." });
	}
	buildPlace(system, project, project.placeProject, place);
	io.stdout(`Created ${relative(project, place)} from ${HYBRID_START_PROJECT_FILE}. Save your world in it; npm run dev never rebuilds it.\n`);
	return { place, open: true };
}

export async function runDev(system, project, options, io) {
	const port = options.port ?? DEFAULT_ROJO_PORT;
	await assertPortAvailable(port, options.port !== undefined);
	const studio = options.open ? resolveStudio(system, options.studioPath) : undefined;
	const prepared = preparePlace(system, project, options, io);

	const serve = startRojoServe(system, project, project.codeProject, port);
	let stopping = false;
	const stop = () => {
		stopping = true;
		serve.child.kill();
	};
	const removeInterrupt = system.onInterrupt(stop);
	let autoCapture;

	try {
		const readyPort = await serve.ready;
		io.stdout(`Rojo is serving ${ROJO_PROJECT_FILE} on localhost:${readyPort}.\n`);
		serve.child.stdout.on("data", (chunk) => io.stdout(chunk.toString()));
		serve.child.stderr.on("data", (chunk) => io.stderr(chunk.toString()));

		if (studio !== undefined && prepared.open) {
			const opened = await openInStudio(system, studio, prepared.place);
			if (!opened.ok) {
				io.stderr(`Roblox Studio did not open ${relative(project, prepared.place)}: ${opened.detail}. Open it yourself.\n`);
			} else {
				io.stdout(`Opened ${relative(project, prepared.place)} in Roblox Studio.\n`);
			}
		} else if (prepared.open) {
			io.stdout(`Open ${relative(project, prepared.place)} in Roblox Studio.\n`);
		}

		if (options.capture) autoCapture = startAutoCapture(system, project, prepared.place, io, { watch: system.watch });

		io.stdout(
			`In Studio, open the Rojo plugin, connect to localhost:${readyPort}, then press Play. If the plugin is missing or older than Rojo 7.7, run rojo plugin install.\nPress Ctrl+C to stop Rojo; Studio stays open.\n`,
		);

		const code = await serve.exited;
		if (stopping) return ExitCode.ok;
		throw new KrfToolError("RojoServeFailed", `rojo serve stopped unexpectedly with code ${code}.`);
	} catch (error) {
		if (!stopping) serve.child.kill();
		throw error;
	} finally {
		autoCapture?.stop();
		removeInterrupt();
	}
}
