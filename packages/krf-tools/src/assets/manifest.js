import { createHash } from "node:crypto";
import path from "node:path";
import { z } from "zod";

import { isIdentifier } from "../generate/luau.js";

export const MANIFEST_FILE = "assets/manifest.json";
export const ASSET_MODULE_FILE = "src/shared/GameAssets.luau";
export const ASSET_KINDS = Object.freeze(["Animation", "Audio", "Image", "Mesh"]);

const SHA256 = /^[0-9a-f]{64}$/;
const robloxId = z
	.number({ error: "must be the numeric Roblox asset ID, such as 1234567890" })
	.int({ error: "must be a whole number" })
	.positive({ error: "must be positive" })
	.max(Number.MAX_SAFE_INTEGER, { error: "is too large for a Roblox asset ID" });

const assetSchema = z.strictObject({
	name: z.string(),
	kind: z.enum(ASSET_KINDS, { error: `must be one of ${ASSET_KINDS.join(", ")}` }),
	id: robloxId,
	source: z.string().optional(),
	sha256: z.string().regex(SHA256, { error: "must be 64 lowercase hexadecimal characters" }).optional(),
	owner: z.union([z.strictObject({ user: robloxId }), z.strictObject({ group: robloxId })], { error: 'must be { "user": <id> } or { "group": <id> }' }).optional(),
});

const manifestSchema = z.strictObject({ assets: z.array(assetSchema) });

export function sha256(contents) {
	return createHash("sha256").update(contents).digest("hex");
}

function issuePath(issuePath, assets) {
	const [, index, field] = issuePath;
	if (issuePath[0] !== "assets" || typeof index !== "number") return issuePath.join(".") || "manifest";
	const name = typeof assets?.[index]?.name === "string" ? assets[index].name : `assets[${index}]`;
	return field === undefined ? name : `${name}.${field}`;
}

function sourceProblem(source) {
	const normalized = path.posix.normalize(source);
	if (source === "" || path.posix.isAbsolute(source) || path.win32.isAbsolute(source) || source.includes("\\") || normalized !== source || source.startsWith("../")) {
		return "must be a project-relative path with forward slashes, such as assets/animations/Fireball.rbxm";
	}
	return undefined;
}

export function renderAssetModule(assets) {
	const entries = [...assets].sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
	if (entries.length === 0) return "--!strict\nreturn table.freeze({})\n";
	return `--!strict\nreturn table.freeze({\n${entries.map((asset) => `\t${asset.name} = "rbxassetid://${asset.id}",`).join("\n")}\n})\n`;
}

export function checkManifest(consumer, text) {
	const problems = [];
	let raw;
	try {
		raw = JSON.parse(text);
	} catch (error) {
		return { problems: [`${MANIFEST_FILE} is not valid JSON: ${error.message}`], fixes: [] };
	}

	const parsed = manifestSchema.safeParse(raw);
	if (!parsed.success) {
		return { problems: parsed.error.issues.map((issue) => `${issuePath(issue.path, raw?.assets)}: ${issue.message}`), fixes: [] };
	}

	const assets = parsed.data.assets;
	const fixes = [];
	const seen = new Set();
	for (const [index, asset] of assets.entries()) {
		if (!isIdentifier(asset.name)) problems.push(`${asset.name || `assets[${index}]`}: name must be a Luau identifier, such as FireballCast`);
		if (seen.has(asset.name)) problems.push(`${asset.name}: the name is used by more than one asset`);
		seen.add(asset.name);

		if (asset.source === undefined) {
			if (asset.sha256 !== undefined) problems.push(`${asset.name}: sha256 is set but there is no source file to hash`);
			continue;
		}
		const invalid = sourceProblem(asset.source);
		if (invalid !== undefined) {
			problems.push(`${asset.name}.source: ${invalid}`);
			continue;
		}
		const stats = consumer.stat(asset.source);
		if (stats === undefined || !stats.isFile()) {
			problems.push(`${asset.name}.source: ${asset.source} does not exist`);
			continue;
		}
		const hash = sha256(consumer.readBytes(asset.source));
		if (asset.sha256 === undefined) fixes.push({ kind: "hash", index, hash, message: `${asset.name}: sha256 of ${asset.source} is not recorded` });
		else if (asset.sha256 !== hash) {
			problems.push(
				`${asset.name}: ${asset.source} changed since its sha256 was recorded. Upload the new file to Roblox, set the new id, and remove sha256 so npm run assets:check -- --write records it again`,
			);
		}
	}

	const module = renderAssetModule(assets);
	const current = consumer.read(ASSET_MODULE_FILE);
	if (current?.replace(/\r\n/g, "\n") !== module) {
		fixes.push({ kind: "module", before: current, after: module, message: `${ASSET_MODULE_FILE} ${current === undefined ? "does not exist" : "does not match the manifest"}` });
	}

	return { problems, fixes, raw, assets, module };
}

export function withRecordedHashes(raw, fixes) {
	const assets = raw.assets.map((asset, index) => {
		const fix = fixes.find((candidate) => candidate.kind === "hash" && candidate.index === index);
		if (fix === undefined) return asset;
		const entries = Object.entries(asset).filter(([key]) => key !== "sha256");
		const at = entries.findIndex(([key]) => key === "source") + 1;
		entries.splice(at, 0, ["sha256", fix.hash]);
		return Object.fromEntries(entries);
	});
	return `${JSON.stringify({ ...raw, assets }, null, 2)}\n`;
}
