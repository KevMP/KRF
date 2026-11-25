import path from "node:path";

import { keyName, namedPlaces } from "./config.js";

const ENVIRONMENTS = { dev: "Dev", qa: "QA", prod: "Production" };
const REASONS = {
	PlaceOngoingTeamCreateSession: "Roblox will not publish a place while it is open in Team Create. Close it in Studio, wait a minute and deploy again.",
};
const HTTP = {
	401: "Roblox did not accept the key. Check that it is enabled and allows this computer's IP address.",
	403: "Roblox refused the key. Check that it has Assets read and write for the group and allows this computer's IP address.",
	413: "Roblox rejected the place file as too large.",
	429: "Roblox is rate limiting uploads. Wait a minute and deploy again.",
};

const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;
const list = (items) => items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;

function universe(target) {
	const name = target.environment === "dev" ? `${target.name}'s Dev universe` : `the ${ENVIRONMENTS[target.environment]} universe`;
	return `${name} (${target.universeId})`;
}

function source(result) {
	const commit = result.source?.commit?.slice(0, 7) ?? "this checkout";
	const ref = result.tag ?? result.ref;
	const from = ref ? `${ref} (${commit})` : commit;
	return result.source?.dirty ? `${from} with uncommitted changes` : from;
}

function table(rows) {
	const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
	return rows.map((row) => `  ${row.map((cell, column) => cell.padEnd(widths[column])).join("  ")}`.trimEnd());
}

function startNote(target, name) {
	return target.places && name === target.startPlace ? "start place" : "";
}

function targetRows(target) {
	return table(namedPlaces(target).map(([name, place]) => [name, `place ${place.placeId}`, startNote(target, name)]));
}

function playUrl(target) {
	const [, place] = namedPlaces(target)[0];
	return place.url ?? `https://www.roblox.com/games/${place.placeId}`;
}

export function describeFailure(outcome) {
	const error = outcome.robloxError;
	if (error?.reason && REASONS[error.reason]) return REASONS[error.reason];
	if (error?.message) return `Roblox said: ${error.message}`;
	if (HTTP[outcome.httpStatus]) return HTTP[outcome.httpStatus];
	if (outcome.httpStatus) return `Roblox rejected the request with HTTP ${outcome.httpStatus}.`;
	if (outcome.hint) return outcome.hint;
	if (outcome.code) return `krf-tools stopped with ${outcome.code}.`;
	return "Roblox rejected the request.";
}

function placeOutcome(outcome) {
	if (outcome.status === "confirmed-published") return `revision ${outcome.revisionId}`;
	if (outcome.status === "failed") return "failed";
	if (outcome.status === "unknown") return "not confirmed";
	return "not published";
}

function formatPublish(result) {
	const target = result.target;
	const places = result.places ? Object.entries(result.places) : [["place", result]];
	const where = universe(target);
	const from = source(result);
	const published = places.filter(([, outcome]) => outcome.status === "confirmed-published").map(([name]) => name);
	const failed = places.filter(([, outcome]) => outcome.status === "failed");
	const uncertain = places.filter(([, outcome]) => outcome.status === "unknown");
	const headline = {
		"confirmed-published": `Published ${from} to ${where}.`,
		partial: `Publishing ${from} to ${where} stopped partway.`,
		failed: `Could not publish ${from} to ${where}.`,
		unknown: `Roblox did not confirm the publish of ${from} to ${where}.`,
	}[result.status];
	const lines = [headline, "", ...table(places.map(([name, outcome]) => [
		name, `place ${outcome.placeId ?? target.placeId}`, placeOutcome(outcome), startNote(target, name),
	]))];

	for (const [name, outcome] of failed) lines.push("", `${name} failed: ${describeFailure(outcome)}`);
	for (const [name, outcome] of uncertain) {
		lines.push("", `${name} was sent to Roblox${outcome.operationId ? ` as operation ${outcome.operationId}` : ""}, but krf-tools never saw the result.`);
	}

	if (result.status === "confirmed-published") {
		lines.push("", `Play it at ${playUrl(target)}`);
	} else if (result.status === "unknown") {
		const leases = [result.lease, ...places.map(([, outcome]) => outcome.lease)].filter(Boolean);
		lines.push(`Check ${list(uncertain.map(([name]) => name))} in Creator Dashboard's version history before deploying again.`);
		if (leases.length) lines.push(`Publishing stays locked until you delete ${list(leases)}.`);
	} else {
		const stale = places.filter(([, outcome]) => outcome.status !== "confirmed-published").map(([name]) => name);
		lines.push("");
		if (published.length) lines.push(`Live with this build: ${list(published)}. Still on the previous revision: ${list(stale)}.`);
		else lines.push("Nothing was published.");
		lines.push("Deploy again once the problem is fixed.");
	}
	return lines;
}

function formatVerified(result) {
	const target = result.target;
	const owner = result.ownershipVerification === "verified-by-roblox"
		? `group ${target.owner.id} owns it`
		: "but did not report who owns it";
	return [
		`Ready to publish ${source(result)} to ${universe(target)}.`,
		"",
		...targetRows(target),
		"",
		`Roblox confirmed these places are in the universe, ${owner}, and the key can publish to it. Nothing was built or published.`,
	];
}

function formatTargets(result) {
	if (!result.targets.length) return ["No deployment targets yet. Add krf.deployment to package.json."];
	const lines = [];
	const section = (environment) => {
		const targets = result.targets.filter((target) => target.environment === environment);
		if (lines.length) lines.push("");
		if (!targets.length) {
			lines.push(`${ENVIRONMENTS[environment]}: not configured`);
			return;
		}
		for (const target of targets) {
			const you = environment === "dev" && target.name === result.developer ? " (you)" : "";
			const label = environment === "dev" ? `Dev: ${target.name}${you}` : ENVIRONMENTS[environment];
			lines.push(`${label}, universe ${target.universeId}`, ...targetRows(target));
			lines.push(`  ${keyName(environment)} ${target.credential === "present" ? "is set" : "is not set here"}.`);
		}
	};
	for (const environment of ["dev", "qa", "prod"]) section(environment);
	return lines;
}

function formatBuild(result, root) {
	const places = Object.entries(result.places);
	return [
		`Built ${plural(places.length, "place")}.`,
		"",
		...table(places.map(([name, place]) => [name, path.relative(root, place.file)])),
	];
}

function formatRelease(command, result) {
	if (command === "release:pr") {
		return [
			`Opened ${result.url} to release ${result.tag}.`,
			"GitHub holds CI on pull requests that Actions opens. Choose Approve workflows to run on the pull request to start it.",
			`Merging it tags ${result.tag} and deploys it to QA.`,
		];
	}
	if (!result.released) return [`package.json is still at ${result.version}, so there is nothing to tag.`];
	return [`Tagged ${result.commit.slice(0, 7)} as ${result.tag} and started the QA deploy.`];
}

export function formatDeployment(command, options, result, root) {
	let lines;
	if (command === "env:list") lines = formatTargets(result);
	else if (command === "build:places") lines = formatBuild(result, root);
	else if (command === "release:pr" || command === "release:tag") lines = formatRelease(command, result);
	else if (options["verify-target"]) lines = formatVerified(result);
	else lines = formatPublish(result);
	return `${lines.join("\n")}\n`;
}

export function progressLine(step, detail) {
	if (step === "verify") return `Checking ${universe(detail)} with Roblox...`;
	if (step === "build") return `Building ${list(detail)}...`;
	return `Publishing ${detail}...`;
}
