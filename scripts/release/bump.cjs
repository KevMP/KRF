// Version bumps for release PRs: choosing the next version and rewriting every file that names it.
"use strict";

const { parseReleaseTag, compareVersions } = require("./manifest.cjs");

const BUMPS = ["major", "minor", "patch"];

/**
 * Chooses the next stable version from a bump level or an explicit MAJOR.MINOR.PATCH version.
 * @param {string} current
 * @param {string} target `major`, `minor`, `patch` or an explicit version
 * @returns {{ ok: true, version: string } | { ok: false, reason: string }}
 */
function nextVersion(current, target) {
	const [major, minor, patch] = current.split(".").map(Number);

	if (target === "major") return { ok: true, version: `${major + 1}.0.0` };
	if (target === "minor") return { ok: true, version: `${major}.${minor + 1}.0` };
	if (target === "patch") return { ok: true, version: `${major}.${minor}.${patch + 1}` };

	const explicit = parseReleaseTag(`v${target}`);
	if (!explicit.ok) {
		return { ok: false, reason: `Use ${BUMPS.join(", ")} or a MAJOR.MINOR.PATCH version; got '${target}'` };
	}

	if (compareVersions(explicit.version, current) <= 0) {
		return { ok: false, reason: `${explicit.version} is not newer than the current version ${current}` };
	}

	return { ok: true, version: explicit.version };
}

const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Rewrites `version` inside the [package] table only, leaving dependency tables untouched. */
function bumpManifest(text, from, to) {
	let inPackage = false;
	let replaced = 0;

	const lines = text.split("\n").map((line) => {
		const table = line.trim().match(/^\[([^\]]+)\]$/);
		if (table) {
			inPackage = table[1].trim() === "package";
			return line;
		}

		if (!inPackage) return line;

		const next = line.replace(new RegExp(`^(\\s*version\\s*=\\s*)"${escape(from)}"`), (_, prefix) => `${prefix}"${to}"`);
		if (next !== line) replaced += 1;
		return next;
	});

	return { text: lines.join("\n"), replaced };
}

/** Rewrites the lockfile entry for the package itself, not for any dependency. */
function bumpLockfile(text, name, from, to) {
	let replaced = 0;
	const pattern = new RegExp(`(\\[\\[package\\]\\]\\r?\\nname = "${escape(name)}"\\r?\\nversion = )"${escape(from)}"`, "g");
	const next = text.replace(pattern, (_, prefix) => {
		replaced += 1;
		return `${prefix}"${to}"`;
	});

	return { text: next, replaced };
}

/** Rewrites install snippets such as `KRF = "kevmp/krf@0.1.0"`. */
function bumpInstallSnippets(text, name, from, to) {
	let replaced = 0;
	const next = text.replace(new RegExp(`"${escape(name)}@${escape(from)}"`, "g"), () => {
		replaced += 1;
		return `"${name}@${to}"`;
	});

	return { text: next, replaced };
}

/**
 * Applies a version bump to the release files. Every file must contain the current version, so a
 * moved or reworded reference fails the bump instead of silently going stale.
 * @param {{ manifest: string, lockfile: string, installDocs: Record<string, string> }} files
 * @param {{ name: string, from: string, to: string }} bump
 * @returns {{ ok: true, manifest: string, lockfile: string, installDocs: Record<string, string> }
 *   | { ok: false, reason: string }}
 */
function applyVersionBump(files, { name, from, to }) {
	const manifest = bumpManifest(files.manifest, from, to);
	if (manifest.replaced !== 1) return { ok: false, reason: `wally.toml [package] does not declare version ${from}` };

	const lockfile = bumpLockfile(files.lockfile, name, from, to);
	if (lockfile.replaced !== 1) return { ok: false, reason: `wally.lock has no ${name}@${from} entry` };

	const installDocs = {};
	for (const [file, text] of Object.entries(files.installDocs)) {
		const snippet = bumpInstallSnippets(text, name, from, to);
		if (snippet.replaced === 0) return { ok: false, reason: `${file} does not name "${name}@${from}"` };
		installDocs[file] = snippet.text;
	}

	return { ok: true, manifest: manifest.text, lockfile: lockfile.text, installDocs };
}

/**
 * Describes the pull request that proposes a version bump.
 * @param {{ name: string, from: string, to: string }} bump
 * @returns {{ branch: string, title: string, body: string }}
 */
function releasePullRequest({ name, from, to }) {
	const tag = `v${to}`;

	return {
		branch: `release/${tag}`,
		title: `chore(release): ${tag}`,
		body: [
			`Bumps \`${name}\` from ${from} to ${to} in \`wally.toml\`, \`wally.lock\` and the install snippets.`,
			`Merging publishes ${tag} to Wally after CI passes on \`main\`.`,
			"The GitHub Release notes list the pull requests merged since the previous release.",
		].join(" "),
	};
}

module.exports = { BUMPS, nextVersion, applyVersionBump, releasePullRequest };
