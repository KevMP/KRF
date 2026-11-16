// Interprets `wally publish` output. Wally 0.3.2 exits 0 after an HTTP failure, so the
// process status alone never proves a publish succeeded.
"use strict";

const SUCCESS_LINE = "Package published successfully!";

/**
 * @param {{ exitCode: number | null, stdout: string, stderr: string }} result
 * @returns {{ state: "published" } | { state: "rejected", status: number | null, detail: string } | { state: "failed", detail: string }}
 */
function classifyPublishResult(result) {
	const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
	const errorStatus = output.match(/^Error: (\d{3})\b.*$/m);

	if (errorStatus) {
		return {
			state: "rejected",
			status: Number(errorStatus[1]),
			detail: output.slice(errorStatus.index).trim().slice(0, 2000),
		};
	}

	if (result.exitCode !== 0) {
		return { state: "failed", detail: `wally publish exited with ${result.exitCode}: ${output.trim().slice(0, 2000)}` };
	}

	if (!output.split(/\r?\n/).some((line) => line.trim() === SUCCESS_LINE)) {
		return { state: "failed", detail: "wally publish exited 0 without reporting a successful upload" };
	}

	return { state: "published" };
}

/**
 * Explains a rejected publish for the release summary.
 * @param {number | null} status
 * @param {string} [detail] The registry's response, which names GitHub auth failures under any status
 */
function describeRejection(status, detail = "") {
	if (/Github auth/i.test(detail)) {
		return "The registry rejected WALLY_PUBLISH_TOKEN; it must be the token `wally login` stores in ~/.wally/auth.toml";
	}
	if (status === 401 || status === 403) return "The registry rejected the credentials or scope ownership";
	if (status === 409) return "The registry already has this version";
	if (status === 400 || status === 422) return "The registry rejected the package contents or manifest";
	if (status !== null && status >= 500) return "The registry failed while publishing; verify before retrying";
	return "The registry rejected the publish";
}

module.exports = { classifyPublishResult, describeRejection, SUCCESS_LINE };
