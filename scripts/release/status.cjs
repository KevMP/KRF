// Release status derived from Git tags, tagged manifests, the registry and GitHub Releases.
// A GitHub Release exists only after the release workflow verified a clean consumer install.
"use strict";

const { compareVersions } = require("./manifest.cjs");

const STATES = Object.freeze({
	verified: "Released and verified",
	candidate: "Candidate on main (not yet tagged)",
	unpublished: "Tagged but not published",
	unverified: "Present in registry, consumer verification incomplete/failed",
	mismatch: "Tag/manifest mismatch",
	unknown: "Registry unavailable / status unknown",
	untagged: "In registry without a release tag",
});

/**
 * @param {{
 *   tags: { tag: string, version: string, sha: string, manifestVersion: string | null }[],
 *   main: { sha: string, version: string },
 *   registry: { state: "present", versions: string[] } | { state: "absent" } | { state: "unknown", reason: string },
 *   verifiedVersions: Set<string>,
 * }} input
 */
function deriveReleaseStatus(input) {
	const registryVersions = input.registry.state === "present" ? new Set(input.registry.versions) : new Set();
	const rows = [];

	const tags = [...input.tags].sort((left, right) => compareVersions(right.version, left.version));

	for (const tag of tags) {
		let state;
		if (tag.manifestVersion !== tag.version) state = STATES.mismatch;
		else if (input.registry.state === "unknown") state = STATES.unknown;
		else if (!registryVersions.has(tag.version)) state = STATES.unpublished;
		else if (!input.verifiedVersions.has(tag.version)) state = STATES.unverified;
		else state = STATES.verified;

		rows.push({ subject: tag.tag, sha: tag.sha, manifestVersion: tag.manifestVersion, state });
	}

	const taggedVersions = new Set(tags.map((tag) => tag.version));

	if (!taggedVersions.has(input.main.version)) {
		rows.push({ subject: "main", sha: input.main.sha, manifestVersion: input.main.version, state: STATES.candidate });
	}

	for (const version of [...registryVersions].sort(compareVersions).reverse()) {
		if (!taggedVersions.has(version)) {
			rows.push({ subject: version, sha: null, manifestVersion: null, state: STATES.untagged });
		}
	}

	const latestTag = tags[0] ?? null;
	const latestVerified =
		[...registryVersions].filter((version) => input.verifiedVersions.has(version)).sort(compareVersions).pop() ?? null;

	const healthy = rows.every((row) => row.state === STATES.verified || row.state === STATES.candidate);

	return { rows, latestTag, latestVerified, healthy, registry: input.registry };
}

/** Renders the status as GitHub-flavored Markdown for the Actions job summary. */
function renderReleaseStatus(status, mainVersion) {
	const registryLine =
		status.registry.state === "unknown"
			? `Unknown (${status.registry.reason})`
			: status.registry.state === "absent"
				? "No published versions"
				: status.registry.versions.slice().sort(compareVersions).join(", ");

	const lines = [
		"## KRF release status",
		"",
		"| Item | Value |",
		"| --- | --- |",
		`| Latest release tag | ${status.latestTag ? `${status.latestTag.tag} (\`${status.latestTag.sha.slice(0, 12)}\`)` : "None"} |`,
		`| Tagged manifest version | ${status.latestTag?.manifestVersion ?? "None"} |`,
		`| Manifest version on main | ${mainVersion} |`,
		`| Latest verified registry version | ${status.latestVerified ?? "None"} |`,
		`| Registry versions | ${registryLine} |`,
		"",
		"| Subject | Commit | Manifest | State |",
		"| --- | --- | --- | --- |",
		...status.rows.map(
			(row) => `| ${row.subject} | ${row.sha ? `\`${row.sha.slice(0, 12)}\`` : "-"} | ${row.manifestVersion ?? "-"} | ${row.state} |`,
		),
	];

	return `${lines.join("\n")}\n`;
}

module.exports = { deriveReleaseStatus, renderReleaseStatus, STATES };
