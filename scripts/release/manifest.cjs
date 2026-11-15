// Release identity: tag syntax and the [package] fields of wally.toml.
"use strict";

const RELEASE_TAG = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const PACKAGE_NAME = /^[a-z0-9-]+\/[a-z0-9-]+$/;

/**
 * Parses a stable runtime release tag. Prerelease and build suffixes are not accepted.
 * @param {string} tag
 * @returns {{ ok: true, version: string } | { ok: false, reason: string }}
 */
function parseReleaseTag(tag) {
	if (typeof tag !== "string" || !RELEASE_TAG.test(tag)) {
		return { ok: false, reason: `Release tags must match vMAJOR.MINOR.PATCH; got '${tag}'` };
	}

	return { ok: true, version: tag.slice(1) };
}

/**
 * Reads quoted string keys from the [package] table of a wally.toml document.
 * Only the subset KRF's manifest uses is supported: `key = "value"` lines.
 * @param {string} text
 * @returns {{ name: string, version: string, private: boolean }}
 */
function readPackageManifest(text) {
	const fields = {};
	let inPackage = false;

	for (const rawLine of text.split(/\r?\n/)) {
		const line = rawLine.trim();
		if (line === "" || line.startsWith("#")) continue;

		const table = line.match(/^\[([^\]]+)\]$/);
		if (table) {
			inPackage = table[1].trim() === "package";
			continue;
		}

		if (!inPackage) continue;

		const entry = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(.+)$/);
		if (!entry) continue;

		const value = entry[2].trim();
		const quoted = value.match(/^"([^"\\]*)"$/);
		if (quoted) fields[entry[1]] = quoted[1];
		else if (value === "true" || value === "false") fields[entry[1]] = value === "true";
	}

	if (typeof fields.name !== "string" || !PACKAGE_NAME.test(fields.name)) {
		throw new Error("wally.toml [package] name must be a quoted scope/name");
	}

	if (typeof fields.version !== "string" || !RELEASE_TAG.test(`v${fields.version}`)) {
		throw new Error("wally.toml [package] version must be a quoted MAJOR.MINOR.PATCH version");
	}

	return { name: fields.name, version: fields.version, private: fields.private === true };
}

/**
 * Confirms a release tag names the exact version of the manifest at the tagged commit.
 * @param {string} tag
 * @param {{ name: string, version: string, private: boolean }} manifest
 * @returns {{ ok: true, version: string } | { ok: false, reason: string }}
 */
function checkTagMatchesManifest(tag, manifest) {
	const parsed = parseReleaseTag(tag);
	if (!parsed.ok) return parsed;

	if (manifest.private) {
		return { ok: false, reason: "wally.toml marks the package private" };
	}

	if (parsed.version !== manifest.version) {
		return { ok: false, reason: `Tag ${tag} does not match wally.toml version ${manifest.version}` };
	}

	return { ok: true, version: parsed.version };
}

/**
 * Orders stable versions ascending.
 * @param {string} left
 * @param {string} right
 */
function compareVersions(left, right) {
	const a = left.split(".").map(Number);
	const b = right.split(".").map(Number);

	for (let index = 0; index < 3; index += 1) {
		if (a[index] !== b[index]) return a[index] - b[index];
	}

	return 0;
}

module.exports = { parseReleaseTag, readPackageManifest, checkTagMatchesManifest, compareVersions };
