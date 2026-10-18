// Rebuild paired before/after summaries from retained raw observations. No timing gates.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");
const directory = process.argv[2] || "tests/benchmarks/results/n4-performance-2026-10-18";
const groups = new Map();
const runs = [];
function distribution(values) {
	const sorted = values.toSorted((a, b) => a - b);
	const at = p => sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? 0;
	return { count: sorted.length, median: at(.5), p95: sorted.length >= 20 ? at(.95) : null,
		p99: sorted.length >= 100 ? at(.99) : null, max: sorted.at(-1) ?? 0,
		total: sorted.reduce((sum, value) => sum + value, 0) };
}
for (const file of fs.readdirSync(directory).filter(file => /^(before|after)-(short|sustained|native)-run\d+\.json\.gz$/.test(file)).sort()) {
	const result = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(directory, file))).toString("utf8"));
	if (result.success !== true) throw new Error(`Failed run: ${file}`);
	const [, version, profile] = file.match(/^(before|after)-(short|sustained|native)-/);
	runs.push({ file, environment: result.environment, cases: result.cases.length,
		sha256: crypto.createHash("sha256").update(fs.readFileSync(path.join(directory, file))).digest("hex") });
	for (const entry of result.cases) {
		const key = [profile, entry.actors, entry.mode, entry.syntheticActionsLobbyWide ?? 0,
			entry.recipients ?? 2, entry.diagnostic ?? false].join("/");
		if (!groups.has(key)) groups.set(key, { before: [], after: [] });
		groups.get(key)[version].push({ file, entry });
	}
}
if (!runs.length) throw new Error(`No retained N4 runs in ${directory}`);
function summarize(cases, native) {
	if (!cases.length) return null;
	const merge = name => cases.flatMap(({ entry }) => entry.raw[name] || []);
	const commits = cases.reduce((sum, { entry }) => sum + entry.commits, 0);
	const mutation = distribution(merge("mutationUs"));
	const step = distribution(native ? merge("n4Steps").map(sample => sample[1]) : merge("stepUs"));
	const stages = {};
	for (const { entry } of cases) for (const tick of entry.raw.stages || []) {
		for (const [name, sample] of Object.entries(tick)) {
			stages[name] ||= { totalUs: 0, calls: 0 };
			stages[name].totalUs += sample.totalUs;
			stages[name].calls += sample.calls;
		}
	}
	const authority = distribution(merge("authorityInclusiveUs"));
	const stageUsPerCommit = Object.fromEntries(Object.entries(stages).map(([name, sample]) => [name, sample.totalUs / commits]));
	const n3UsPerCommit = stages.commitInclusiveUs ? (stages.commitInclusiveUs.totalUs - authority.total +
		(stages.n3ObserverUs?.totalUs || 0) + (stages.tagN3ObserverUs?.totalUs || 0) - (stages.n4CommitUs?.totalUs || 0)) / commits : null;
	return { runs: cases.length, commits, mutationUs: mutation, n4StepUs: step,
		totalCpuUsPerCommit: (mutation.total + step.total) / commits,
		tickCpuUs: distribution(merge(native ? "tickCpuUs" : "tickUs")),
		serverHeartbeatMs: native ? distribution(merge("serverHeartbeatMs")) : undefined,
		observedMs: native ? distribution(merge("observedMs")) : undefined,
		queueWaitSteps: native ? undefined : distribution(merge("queueWaitSteps")),
		sentinelWaitSteps: merge("sentinelWaitSteps").length ? distribution(merge("sentinelWaitSteps")) : undefined,
		packetBytes: distribution(merge("packetBytes")), stageUsPerCommit, stageCalls: Object.fromEntries(Object.entries(stages).map(([name, sample]) => [name, sample.calls])), n3UsPerCommit,
		perRun: cases.map(({ file, entry }) => {
			const heap = entry.raw.heapKiB.map(value => Array.isArray(value) ? value[1] : value);
			return { file, commits: entry.commits, deliveredRecords: entry.deliveredRecords,
				mutationTotalUs: entry.mutationUs.total, n4TotalUs: native ? entry.raw.n4Steps.reduce((sum, sample) => sum + sample[1], 0) : entry.stepUs.total,
				drainSteps: entry.drainSteps, maxPendingRecords: entry.maxPendingRecords, maxPendingEvents: entry.maxPendingEvents,
				maxQueuedBytes: entry.maxQueuedBytes, replacements: entry.replacements, replacedCommitOccurrences: entry.replacedCommitOccurrences,
				packets: native ? entry.clients.reduce((sum, client) => sum + client.packets, 0) : entry.packets,
				payloadBytes: native ? entry.clients.reduce((sum, client) => sum + client.bytes, 0) : entry.payloadBytes,
				phases: entry.phases, queueSamples: entry.raw.queueSamples,
				heap: { minKiB: Math.min(...heap), maxKiB: Math.max(...heap), startKiB: heap[0], endKiB: heap.at(-1),
					downwardSamples: heap.slice(1).filter((value, index) => value < heap[index]).length } };
		}) };
}
const summaries = [...groups].map(([key, cases]) => {
	const before = summarize(cases.before, key.startsWith("native/"));
	const after = summarize(cases.after, key.startsWith("native/"));
	return { key, before, after, cpuReductionPercent: before && after ? 100 * (1 - after.totalCpuUsPerCommit / before.totalCpuUsPerCommit) : null };
});
process.stdout.write(JSON.stringify({ quantiles: "nearest rank; pooled individual samples; p95 >=20, p99 >=100; trial count is separate; no confidence intervals", runs, summaries }, null, 2) + "\n");
