import fs from "node:fs";
import path from "node:path";
import { z } from "zod";

import { KrfToolError } from "../errors.js";
import { placeName } from "../project.js";

const layoutSchema = z.object({
	placeProjects: z.record(placeName, z.string().regex(/^(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_.-]+\.project\.json$/)).optional(),
	startPlace: placeName.optional(),
});

function discoverProjects(root) {
	const directory = path.join(root, "places");
	if (!fs.existsSync(directory)) return {};
	const files = fs.readdirSync(directory).filter((file) => file.endsWith(".project.json")).sort();
	const projects = files.map((file) => [file.slice(0, -".project.json".length), `places/${file}`]);
	if (projects.some(([name]) => !placeName.safeParse(name).success)) {
		throw new KrfToolError("invalid-place-layout", "Use valid lowercase place names for the Rojo projects in places/.");
	}
	return Object.fromEntries(projects);
}

export function readPlaceLayout(project, config = JSON.parse(fs.readFileSync(path.join(project.root, "package.json"), "utf8")).krf ?? {}) {
	const parsed = layoutSchema.safeParse(config);
	if (!parsed.success) throw new KrfToolError("invalid-place-layout", "Check krf.placeProjects and krf.startPlace in package.json.");
	const { startPlace, placeProjects = discoverProjects(project.root) } = parsed.data;
	const names = Object.keys(placeProjects).sort();
	if (names.length === 0 && startPlace === undefined && parsed.data.placeProjects === undefined) return {};
	if (!names.includes(startPlace)) throw new KrfToolError("invalid-place-layout", "Set krf.startPlace in package.json to the name of a configured Rojo place.");
	return { startPlace, placeProjects: Object.fromEntries(names.map((name) => [name, placeProjects[name]])) };
}

export function resolvePlaceProject(root, projectFile) {
	const absolute = path.join(root, projectFile);
	if (!fs.lstatSync(absolute, { throwIfNoEntry: false })?.isFile() ||
		path.relative(fs.realpathSync(root), fs.realpathSync(absolute)).split(path.sep).join("/") !== projectFile) {
		throw new KrfToolError("RojoProjectMissing", `Use a regular Rojo project file inside the project. Check ${projectFile}.`);
	}
	return absolute;
}
