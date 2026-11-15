// Package contents: the allowed archive file set and content comparison against the registry.
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const ROOT_FILES = new Set(["default.project.json", "wally.toml", "LICENSE"]);
const MAX_ARCHIVE_BYTES = 2 * 1024 * 1024;

/** Normalizes one `wally package --list` line to a forward-slash relative path. */
function normalizeListedPath(line) {
	return line.trim().replace(/\\/g, "/").replace(/^\.\//, "");
}

/**
 * Checks the files Wally would publish. Only the root package files and Luau source under src/ may ship.
 * Directory entries are accepted when they are src/ or one of its descendants.
 * @param {string} listing Output of `wally package --list`.
 * @param {Set<string>} directories Paths in the listing that are directories.
 * @returns {{ ok: boolean, files: string[], unexpected: string[], missing: string[] }}
 */
function validatePackageListing(listing, directories) {
	const files = [];
	const unexpected = [];

	for (const line of listing.split(/\r?\n/)) {
		const entry = normalizeListedPath(line);
		if (entry === "") continue;

		if (directories.has(entry)) {
			if (entry !== "src" && !entry.startsWith("src/")) unexpected.push(entry);
			continue;
		}

		if (ROOT_FILES.has(entry) || /^src\/.+\.luau$/.test(entry)) files.push(entry);
		else unexpected.push(entry);
	}

	const missing = [...ROOT_FILES].filter((file) => !files.includes(file));
	if (!files.some((file) => file.startsWith("src/"))) missing.push("src/**/*.luau");

	return { ok: unexpected.length === 0 && missing.length === 0, files: files.sort(), unexpected, missing };
}

/**
 * Rejects archives Wally's registry would refuse.
 * @param {number} bytes
 */
function checkArchiveSize(bytes) {
	return bytes <= MAX_ARCHIVE_BYTES
		? { ok: true }
		: { ok: false, reason: `Package archive is ${bytes} bytes; Wally rejects archives over ${MAX_ARCHIVE_BYTES}` };
}

function hashBytes(bytes) {
	return crypto.createHash("sha256").update(bytes).digest("hex");
}

/**
 * Hashes every file below a directory by relative path. `default.project.json` is hashed after
 * JSON normalization because Wally re-serializes it during packaging.
 * @param {string} root
 * @returns {Map<string, string>}
 */
function hashTree(root) {
	const hashes = new Map();

	function visit(directory) {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) {
				visit(full);
				continue;
			}

			const relative = path.relative(root, full).split(path.sep).join("/");
			const bytes = fs.readFileSync(full);
			hashes.set(
				relative,
				relative === "default.project.json" ? hashBytes(JSON.stringify(JSON.parse(bytes.toString("utf8")))) : hashBytes(bytes),
			);
		}
	}

	visit(root);
	return hashes;
}

/**
 * Compares two extracted package trees.
 * @param {Map<string, string>} expected
 * @param {Map<string, string>} actual
 * @returns {{ ok: boolean, missing: string[], unexpected: string[], changed: string[] }}
 */
function compareTrees(expected, actual) {
	const missing = [];
	const changed = [];

	for (const [file, hash] of expected) {
		if (!actual.has(file)) missing.push(file);
		else if (actual.get(file) !== hash) changed.push(file);
	}

	const unexpected = [...actual.keys()].filter((file) => !expected.has(file));

	return {
		ok: missing.length === 0 && changed.length === 0 && unexpected.length === 0,
		missing: missing.sort(),
		unexpected: unexpected.sort(),
		changed: changed.sort(),
	};
}

module.exports = { validatePackageListing, checkArchiveSize, hashTree, compareTrees, MAX_ARCHIVE_BYTES };
