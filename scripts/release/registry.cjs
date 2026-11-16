// Wally registry reads. A failed lookup is never treated as proof that a version is absent.
"use strict";

const INDEX_URL = "https://raw.githubusercontent.com/UpliftGames/wally-index/main";
const API_URL = "https://api.wally.run";
const WALLY_VERSION = "0.3.2";

/**
 * @typedef {{ state: "present", versions: string[] } | { state: "absent" } | { state: "unknown", reason: string }} VersionListing
 * @typedef {{ state: "present", bytes: Buffer } | { state: "absent" } | { state: "unknown", reason: string }} ContentsResult
 */

/**
 * @param {{ fetch?: typeof fetch, sleep?: (ms: number) => Promise<void>, indexUrl?: string, apiUrl?: string }} [options]
 */
function createRegistry(options = {}) {
	const request = options.fetch ?? globalThis.fetch;
	const sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
	const indexUrl = options.indexUrl ?? INDEX_URL;
	const apiUrl = options.apiUrl ?? API_URL;

	/**
	 * Lists published versions from the registry's Git index, the source Wally installs resolve from.
	 * @param {string} packageName scope/name
	 * @returns {Promise<VersionListing>}
	 */
	async function listVersions(packageName) {
		let response;
		try {
			response = await request(`${indexUrl}/${packageName}`, { cache: "no-store" });
		} catch (error) {
			return { state: "unknown", reason: `Index request failed: ${error.message}` };
		}

		if (response.status === 404) return { state: "absent" };
		if (!response.ok) return { state: "unknown", reason: `Index returned HTTP ${response.status}` };

		const versions = [];
		for (const line of (await response.text()).split(/\r?\n/)) {
			if (line.trim() === "") continue;
			try {
				const entry = JSON.parse(line);
				if (entry?.package?.name === packageName && typeof entry.package.version === "string") {
					versions.push(entry.package.version);
				}
			} catch {
				return { state: "unknown", reason: "Index entry is not valid JSON" };
			}
		}

		return versions.length === 0 ? { state: "absent" } : { state: "present", versions };
	}

	/**
	 * Downloads the archive the registry serves for one exact version.
	 * @param {string} packageName
	 * @param {string} version
	 * @returns {Promise<ContentsResult>}
	 */
	async function downloadContents(packageName, version) {
		let response;
		try {
			response = await request(`${apiUrl}/v1/package-contents/${packageName}/${version}`, {
				headers: { "Wally-Version": WALLY_VERSION },
			});
		} catch (error) {
			return { state: "unknown", reason: `Contents request failed: ${error.message}` };
		}

		if (response.status === 404) return { state: "absent" };
		if (!response.ok) return { state: "unknown", reason: `Contents API returned HTTP ${response.status}` };

		return { state: "present", bytes: Buffer.from(await response.arrayBuffer()) };
	}

	/**
	 * Waits for a version to appear in the index and the contents API, with bounded retries for propagation.
	 * Absent results keep retrying; the final result reports the last observed state.
	 * @param {string} packageName
	 * @param {string} version
	 * @param {{ attempts?: number, delayMs?: number }} [retry]
	 * @returns {Promise<ContentsResult>}
	 */
	async function awaitVersion(packageName, version, retry = {}) {
		const attempts = retry.attempts ?? 10;
		const delayMs = retry.delayMs ?? 15000;
		let last = { state: "unknown", reason: "No registry attempt was made" };

		for (let attempt = 1; attempt <= attempts; attempt += 1) {
			const listing = await listVersions(packageName);

			if (listing.state === "present" && listing.versions.includes(version)) {
				last = await downloadContents(packageName, version);
				if (last.state === "present") return last;
			} else {
				last = listing.state === "unknown" ? listing : { state: "absent" };
			}

			if (attempt < attempts) await sleep(delayMs);
		}

		return last;
	}

	return { listVersions, downloadContents, awaitVersion };
}

module.exports = { createRegistry, WALLY_VERSION };
