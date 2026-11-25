import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import { formatDeployment, progressLine } from "../src/deploy/report.js";

const target = {
	environment: "dev",
	name: "kevin",
	universeId: "21",
	places: { lobby: { placeId: "31" }, dungeon: { placeId: "32" } },
	owner: { kind: "group", id: "11" },
	startPlace: "lobby",
};
const base = { source: { commit: "a".repeat(40), dirty: true }, target, ownershipVerification: "verified-by-roblox" };
const published = (revisionId, placeId) => ({ status: "confirmed-published", revisionId, placeId });

test("a confirmed deploy lists each place's revision in publish order and links the start place", () => {
	const output = formatDeployment("deploy:dev", {}, { ...base, status: "confirmed-published", places: { dungeon: published("2", "32"), lobby: published("4", "31") } });
	assert.equal(output, [
		"Published aaaaaaa with uncommitted changes to kevin's Dev universe (21).",
		"",
		"  dungeon  place 32  revision 2",
		"  lobby    place 31  revision 4  start place",
		"",
		"Play it at https://www.roblox.com/games/31",
		"",
	].join("\n"));
});

test("a partial deploy explains Roblox's reason and which places are live", () => {
	const output = formatDeployment("deploy:qa", {}, {
		...base,
		ref: "feature/arena",
		source: { commit: "b".repeat(40), dirty: false },
		target: { ...target, environment: "qa", name: "qa" },
		status: "partial",
		places: { dungeon: published("2", "32"), lobby: { status: "failed", placeId: "31", robloxError: { reason: "PlaceOngoingTeamCreateSession" } } },
	});
	assert.match(output, /^Publishing feature\/arena \(bbbbbbb\) to the QA universe \(21\) stopped partway\.$/m);
	assert.match(output, /^ {2}lobby {4}place 31 {2}failed {6}start place$/m);
	assert.match(output, /^lobby failed: Roblox will not publish a place while it is open in Team Create\./m);
	assert.match(output, /^Live with this build: dungeon\. Still on the previous revision: lobby\.$/m);
});

test("an unconfirmed deploy names the operation and every lock to clear", () => {
	const output = formatDeployment("deploy:dev", {}, {
		...base,
		status: "unknown",
		lease: "universe-21.jsonl",
		places: { dungeon: published("2", "32"), lobby: { status: "unknown", placeId: "31", operationId: "op-1", lease: "place-31.jsonl" } },
	});
	assert.match(output, /^lobby was sent to Roblox as operation op-1, but krf-tools never saw the result\.$/m);
	assert.match(output, /^Publishing stays locked until you delete universe-21\.jsonl and place-31\.jsonl\.$/m);
});

test("verification, builds and the environment list describe what they did", () => {
	assert.match(formatDeployment("deploy:dev", { "verify-target": true }, { ...base, status: "validated" }), /group 11 owns it, and the key can publish to it\. Nothing was built or published\.$/m);
	const root = path.resolve("game");
	assert.match(formatDeployment("build:places", {}, { status: "validated", places: { lobby: { file: path.join(root, "build", "places", "lobby.rbxl") } } }, root),
		new RegExp(`^ {2}lobby {2}${path.join("build", "places", "lobby.rbxl").replaceAll("\\", "\\\\")}$`, "m"));
	assert.equal(formatDeployment("env:list", {}, { status: "validated", developer: "kevin", targets: [{ ...target, credential: "present" }] }), [
		"Dev: kevin (you), universe 21",
		"  lobby    place 31  start place",
		"  dungeon  place 32",
		"  KRF_ROBLOX_DEV_KEY is set.",
		"",
		"QA: not configured",
		"",
		"Production: not configured",
		"",
	].join("\n"));
	assert.equal(progressLine("build", ["lobby", "dungeon"]), "Building lobby and dungeon...");
	assert.equal(formatDeployment("release:pr", {}, { status: "validated", tag: "v1.3.0", branch: "release/v1.3.0", url: "https://github.com/group/game/pull/7" }), [
		"Opened https://github.com/group/game/pull/7 to release v1.3.0.",
		"GitHub holds CI on pull requests that Actions opens. Choose Approve workflows to run on the pull request to start it.",
		"Merging it tags v1.3.0 and deploys it to QA.",
		"",
	].join("\n"));
});
