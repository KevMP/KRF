import { ExitCode, KrfToolError } from "../errors.js";
import { applyProjectChanges } from "../files.js";
import { createConsumer, findProjectRoot } from "../generate/consumer.js";
import { ASSET_MODULE_FILE, MANIFEST_FILE, checkManifest, withRecordedHashes } from "./manifest.js";

const UNVERIFIED = "Not checked: whether these IDs exist on Roblox, or whether your account or group may use them. Studio loads an asset only when it can.\n";

const lines = (entries) => entries.map((entry) => `  ${entry}\n`).join("");

export async function runAssetCheck(cwd, options, io) {
	const consumer = createConsumer(findProjectRoot(cwd));
	const text = consumer.read(MANIFEST_FILE);
	if (text === undefined) {
		io.stdout(`No asset manifest at ${MANIFEST_FILE}, so there is nothing to check.\n`);
		return ExitCode.ok;
	}

	const result = checkManifest(consumer, text);
	if (result.problems.length > 0) {
		throw new KrfToolError("AssetCheckFailed", `${MANIFEST_FILE} has ${result.problems.length} problem${result.problems.length === 1 ? "" : "s"}:\n${lines(result.problems).trimEnd()}`, {
			hint: result.fixes.length > 0 ? `Also out of date:\n${lines(result.fixes.map((fix) => fix.message)).trimEnd()}` : undefined,
		});
	}

	if (result.fixes.length > 0 && !options.write) {
		throw new KrfToolError("AssetCheckFailed", `${MANIFEST_FILE} needs updates:\n${lines(result.fixes.map((fix) => fix.message)).trimEnd()}`, {
			hint: "Run npm run assets:check -- --write to record source hashes and regenerate the asset module.",
		});
	}

	if (result.fixes.length > 0) {
		const changes = [];
		if (result.fixes.some((fix) => fix.kind === "hash")) changes.push({ kind: "edit", path: MANIFEST_FILE, before: text, after: withRecordedHashes(result.raw, result.fixes) });
		const module = result.fixes.find((fix) => fix.kind === "module");
		if (module !== undefined) {
			changes.push(module.before === undefined ? { kind: "create", path: ASSET_MODULE_FILE, contents: module.after } : { kind: "edit", path: ASSET_MODULE_FILE, before: module.before, after: module.after });
		}
		applyProjectChanges(consumer.root, changes);
		io.stdout(`Updated ${changes.map((change) => change.path).join(" and ")}.\n`);
	}

	const count = result.assets.length;
	io.stdout(`${MANIFEST_FILE}: ${count} asset${count === 1 ? "" : "s"} passed the local checks (names, IDs, source files, hashes and ${ASSET_MODULE_FILE}).\n${UNVERIFIED}`);
	return ExitCode.ok;
}
