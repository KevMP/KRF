import fs from "node:fs";
import path from "node:path";
import { z } from "zod";

import { KrfToolError } from "../errors.js";
import { placeName } from "../project.js";
import { readPlaceLayout } from "../workflow/place-layout.js";

export const isId = (value) => typeof value === "string" && /^[1-9][0-9]*$/.test(value);
const id = z.string().refine(isId, "Use a positive Roblox ID as a string");
const developer = z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/);
const place = z.strictObject({
	placeId: id,
	url: z.url({ protocol: /^https$/ }).refine((value) => {
		const url = new URL(value);
		return !url.username && !url.password;
	}).optional(),
});
const target = z.union([
	place.extend({ universeId: id }),
	z.strictObject({ universeId: id, places: z.record(placeName, z.union([id, place])) }),
]);

const deployment = z.strictObject({
	owner: z.strictObject({ kind: z.literal("group"), id }),
	developers: z.record(developer, target),
	qa: target.optional(),
	production: target.optional(),
});

function readKrfConfig(project) {
	return JSON.parse(fs.readFileSync(path.join(project.root, "package.json"), "utf8")).krf ?? {};
}

export function readTargets(project) {
	const raw = readKrfConfig(project).deployment;
	if (raw === undefined) return [];
	const parsed = deployment.safeParse(raw);
	if (!parsed.success) {
		const issue = parsed.error.issues[0];
		throw new KrfToolError("invalid-deployment-config", `Check package.json krf.deployment.${issue.path.join(".")}.`);
	}
	const { owner, developers, qa, production } = parsed.data;
	const layout = readPlaceLayout(project);
	const names = Object.keys(layout.placeProjects ?? {}).sort();
	const targets = [
		...Object.entries(developers).map(([name, value]) => ({ environment: "dev", name, ...value })),
		...(qa ? [{ environment: "qa", name: "qa", ...qa }] : []),
		...(production ? [{ environment: "prod", name: "production", ...production }] : []),
	].map((entry) => {
		if (!entry.places && !layout.placeProjects) return { ...entry, owner };
		if (!entry.places || !layout.placeProjects || Object.keys(entry.places).length !== names.length || names.some((name) => !Object.hasOwn(entry.places, name))) {
			throw new KrfToolError("invalid-deployment-config", "Every configured universe must map every named Rojo place exactly once.");
		}
		const places = Object.fromEntries(names.map((name) => {
			const value = entry.places[name];
			return [name, typeof value === "string" ? { placeId: value } : value];
		}));
		return { ...entry, owner, places, ...layout };
	});
	const placeIds = targets.flatMap((entry) => Object.values(entry.places ?? { place: entry }).map((value) => value.placeId));
	if (new Set(targets.map((entry) => entry.universeId)).size !== targets.length || new Set(placeIds).size !== placeIds.length) {
		throw new KrfToolError("overlapping-targets", "Each Dev assignment, QA and Production must have a distinct universe ID and a distinct place ID.");
	}
	return targets;
}

export function namedPlaces(target) {
	if (!target.places) return [["place", target]];
	const { places, startPlace, placeProjects, ...universe } = target;
	return [startPlace, ...Object.keys(places).filter((name) => name !== startPlace)]
		.map((name) => [name, { ...universe, ...places[name] }]);
}

export function selectTarget(targets, environment, name) {
	const target = targets.find((entry) => entry.environment === environment && (environment !== "dev" || entry.name === name));
	if (target === undefined) {
		throw new KrfToolError("target-not-configured", environment === "dev"
			? "Set KRF_DEVELOPER or pass --developer with a Dev assignment from package.json krf.deployment."
			: "Configure QA and Production in package.json krf.deployment.");
	}
	return target;
}

export function requireFull(project) {
	if (project.mode !== "full") {
		throw new KrfToolError("unsupported-project-mode", "Cloud deployment requires a Full Rojo project. Use Studio to publish the world of a Hybrid project.");
	}
}

export function keyName(environment) {
	return `KRF_ROBLOX_${environment.toUpperCase()}_KEY`;
}

export function readCredential(env, target) {
	const key = env[keyName(target.environment)];
	if (!key?.trim()) throw new KrfToolError("missing-credential", `Set ${keyName(target.environment)} with an Assets Read and Write key for group ${target.owner.id}.`);
	return key;
}
