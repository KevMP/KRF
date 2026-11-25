import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { KrfToolError } from "../errors.js";

export async function withPublishJournal(key, evidence, publish) {
	const leases = path.join(os.tmpdir(), "krf-open-cloud");
	fs.mkdirSync(leases, { recursive: true, mode: 0o700 });
	const lease = path.join(leases, `${key}.jsonl`);
	let fd;
	try {
		fd = fs.openSync(lease, "wx", 0o600);
	} catch (error) {
		if (error.code !== "EEXIST") throw error;
		throw new KrfToolError("publish-in-flight", `Another publish is running, or an earlier one was never confirmed. Check the Roblox version history, then delete ${lease} to unlock publishing.`);
	}
	function append(outcome) {
		const line = JSON.stringify({ ...evidence, ...outcome, at: new Date().toISOString() }) + "\n";
		fs.appendFileSync(fd, line);
		fs.fsyncSync(fd);
	}
	let safeToRelease = false;
	try {
		append({ status: "submitting" });
		const outcome = await publish(append);
		append(outcome);
		safeToRelease = ["validated", "confirmed-published", "failed", "partial"].includes(outcome.status);
		return { ...evidence, ...outcome, ...(safeToRelease ? {} : { lease }) };
	} finally {
		fs.closeSync(fd);
		if (safeToRelease) fs.unlinkSync(lease);
	}
}
