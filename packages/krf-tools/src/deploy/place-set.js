import { KrfToolError } from "../errors.js";
import { namedPlaces } from "./config.js";
import { withPublishJournal } from "./journal.js";
import { MAX_PLACE_BYTES } from "./open-cloud.js";

export async function verifyPlaceTargets(cloud, target) {
	const statuses = await Promise.all(namedPlaces(target).map(([name, place]) => cloud.verifyTarget(place, name === target.startPlace)));
	return statuses.includes("owner-unreported") ? "owner-unreported" : "verified-by-roblox";
}

export async function publishPlaces(cloud, target, artifacts, evidence, onPublish = () => {}) {
	const plan = [];
	for (const [name, place] of namedPlaces(target)) {
		const artifact = artifacts.get(name);
		if (!artifact || artifact.bytes.length > MAX_PLACE_BYTES) {
			throw new KrfToolError("unsupported-place-artifact", `Place ${name} requires a built binary place of at most 20 MB.`);
		}
		plan.push({ name, place, artifact });
	}

	function publishOne({ name, place, artifact }) {
		onPublish(name);
		return withPublishJournal(`place-${place.placeId}`, {
			...evidence, target: place, placeSha256: artifact.placeSha256,
		}, (progress) => cloud.publish(place, artifact, progress));
	}

	if (!target.places) return publishOne(plan[0]);
	plan.push(plan.shift());
	return withPublishJournal(`universe-${target.universeId}`, { ...evidence, target }, async (progress) => {
		const places = {};
		let finished = 0;
		for (const { name, place, artifact } of plan) {
			let outcome;
			try {
				outcome = await publishOne({ name, place, artifact });
			} catch (error) {
				outcome = { status: "unknown", code: error instanceof KrfToolError ? error.code : "deployment-error" };
			}
			places[name] = { ...outcome, placeId: place.placeId, placeSha256: artifact.placeSha256 };
			progress({ status: "place-result", name, outcome: places[name] });
			if (outcome.status !== "confirmed-published") {
				for (const pending of plan.slice(finished + 1)) places[pending.name] = { status: "not-attempted", placeId: pending.place.placeId };
				const status = outcome.status !== "failed" ? "unknown" : finished > 0 ? "partial" : "failed";
				return { status, places };
			}
			finished++;
		}
		return { status: "confirmed-published", places };
	});
}
