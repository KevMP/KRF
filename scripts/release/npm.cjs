"use strict";

const { compareVersions } = require("./manifest.cjs");

const RELEASE_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const TRUSTED_PUBLISHING_NPM = "11.5.1";

/**
 * @typedef {{ name: string, version: string, dependencies?: Record<string, string> }} NpmManifest
 * @typedef {{ state: "present", integrity: string } | { state: "absent" } | { state: "unknown", detail: string }} RegistryLookup
 */

/**
 * @param {{ tooling: NpmManifest, creator: NpmManifest }} manifests
 * @returns {{ ok: true } | { ok: false, reason: string }}
 */
function checkReleaseVersions({ tooling, creator }) {
	for (const manifest of [tooling, creator]) {
		if (!RELEASE_VERSION.test(manifest.version)) {
			return { ok: false, reason: `${manifest.name} ${manifest.version} is not a MAJOR.MINOR.PATCH release version` };
		}
	}

	const pinned = creator.dependencies?.[tooling.name];
	if (pinned !== tooling.version) {
		return { ok: false, reason: `${creator.name} must pin ${tooling.name} ${tooling.version} exactly, but depends on ${pinned ?? "nothing"}` };
	}

	return { ok: true };
}

/**
 * @param {string} version
 * @returns {{ ok: true } | { ok: false, reason: string }}
 */
function checkNpmVersion(version) {
	if (!RELEASE_VERSION.test(version) || compareVersions(version, TRUSTED_PUBLISHING_NPM) < 0) {
		return { ok: false, reason: `Trusted publishing needs npm ${TRUSTED_PUBLISHING_NPM} or later, but this runner has npm ${version}` };
	}
	return { ok: true };
}

/**
 * @param {{ exitCode: number | null, stdout: string, stderr: string }} result
 * @returns {RegistryLookup}
 */
function classifyRegistryLookup(result) {
	const stdout = result.stdout.trim();
	if (result.exitCode === 0) {
		if (stdout === "") return { state: "absent" };
		const integrity = JSON.parse(stdout);
		if (typeof integrity === "string" && integrity.startsWith("sha512-")) return { state: "present", integrity };
		return { state: "unknown", detail: `npm view returned ${stdout.slice(0, 200)}` };
	}

	if (/\bE404\b/.test(`${stdout}\n${result.stderr}`)) return { state: "absent" };
	return { state: "unknown", detail: (result.stderr || stdout).trim().slice(0, 2000) };
}

/**
 * @param {string} label
 * @param {RegistryLookup} lookup
 * @param {string} integrity
 * @returns {{ action: "publish" } | { action: "skip" } | { action: "stop", reason: string }}
 */
function decidePublish(label, lookup, integrity) {
	if (lookup.state === "absent") return { action: "publish" };
	if (lookup.state === "unknown") return { action: "stop", reason: `Could not read ${label} from npm: ${lookup.detail}` };
	if (lookup.integrity === integrity) return { action: "skip" };
	return { action: "stop", reason: `npm already has ${label} with different contents. Release a new version instead.` };
}

module.exports = { checkReleaseVersions, checkNpmVersion, classifyRegistryLookup, decidePublish, TRUSTED_PUBLISHING_NPM };
