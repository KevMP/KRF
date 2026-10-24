// Analyze local raw JSON or gzip JSON; no timing thresholds or CI gates.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const directory = process.argv[2] || "build/networking-analysis";
const quantile = (sorted, probability) => sorted[Math.max(0, Math.ceil(sorted.length * probability) - 1)] ?? 0;
function distribution(values) {
	const sorted = values.toSorted((a, b) => a - b);
	return {
		count: sorted.length,
		median: quantile(sorted, 0.5),
		p95: sorted.length >= 20 ? quantile(sorted, 0.95) : null,
		p99: sorted.length >= 100 ? quantile(sorted, 0.99) : null,
		max: sorted.at(-1) ?? 0,
		total: sorted.reduce((sum, value) => sum + value, 0),
	};
}
function load(file) {
	const bytes = fs.readFileSync(path.join(directory, file));
	return JSON.parse((file.endsWith(".gz") ? zlib.gunzipSync(bytes) : bytes).toString("utf8").replace(/^\uFEFF/, ""));
}
const files = fs.readdirSync(directory).filter(file => /^(native|cpu|audit)-run\d+\.json(\.gz)?$/.test(file)).sort();
if (new Set(files.map(file => file.replace(/\.gz$/, ""))).size !== files.length) {
	throw new Error("Duplicate plain/gzip observations would count the same trial twice");
}
if (!files.length) throw new Error(`No local benchmark runs in ${directory}`);
const groups = new Map();
const runs = [];
let auditEnvironment;
for (const file of files) {
	const result = load(file);
	if (result.success !== true) throw new Error(`Failed benchmark ${file}`);
	if (file.startsWith("audit-")) {
		const environment = result.environment;
		const signature = JSON.stringify([result.workloadVersion, environment?.implementationRevision,
			environment?.studioFileVersion,
			Object.entries(environment?.harnessSHA256 ?? {}).sort(([a], [b]) => a.localeCompare(b)),
			Object.entries(environment?.sourceSHA256 ?? {}).sort(([a], [b]) => a.localeCompare(b))]);
		if (!environment?.sourceSHA256 || !environment?.harnessSHA256?.["tests/benchmarks/NetworkingAudit.luau"]) {
			throw new Error(`Missing audit source provenance: ${file}`);
		}
		if (auditEnvironment && auditEnvironment !== signature) throw new Error(`Mixed audit implementation/harness/Studio: ${file}`);
		auditEnvironment = signature;
	}
	runs.push({ file, environment: result.environment, cases: result.cases.length });
	for (const entry of result.cases) {
		if (file.startsWith("audit-")) {
			if (result.workloadVersion !== 1) throw new Error(`Unsupported audit workload: ${file}`);
			const key = ["audit", entry.kind, entry.actors ?? entry.size ?? entry.width ?? 0, entry.recipients ?? entry.barriers ?? 1,
				entry.mode ?? entry.malformed ?? "", entry.diagnostic ?? false].join("/");
			if (!groups.has(key)) groups.set(key, []);
			groups.get(key).push({ file, entry });
			continue;
		}
		const kind = file.startsWith("cpu-") ? "cpu" : "native";
		const key = [kind, entry.actors, entry.mode, entry.syntheticActionsLobbyWide ?? 0, entry.recipients ?? 2, entry.diagnostic ?? false].join("/");
		if (!groups.has(key)) groups.set(key, []);
		groups.get(key).push({ file, entry });
	}
}
const summaries = [];
for (const [key, cases] of groups) {
	if (key.startsWith("audit/")) {
		// Audit quantiles are per trial. Never average p95/p99 and label them pooled.
		summaries.push({ key, runs: cases.length, perRun: cases.map(({ file, entry }) => ({ file, ...entry })) });
		continue;
	}
	const merge = name => cases.flatMap(({ entry }) => entry.raw[name] || []);
	const stages = {};
	for (const { entry } of cases) {
		for (const tick of entry.raw.stages || []) {
			for (const [name, sample] of Object.entries(tick)) {
				stages[name] ||= { totalUs: 0, calls: 0 };
				stages[name].totalUs += sample.totalUs;
				stages[name].calls += sample.calls;
			}
		}
	}
	const commits = cases.reduce((sum, { entry }) => sum + (entry.commits || 0), 0);
	const stageMeanUsPerCommit = Object.fromEntries(Object.entries(stages).map(([name, value]) => [name, value.totalUs / commits]));
	const stageWorkloadTickUs = Object.fromEntries(Object.keys(stages).map(name => [name,
		distribution(cases.flatMap(({ entry }) => entry.raw.stages.slice(0, 180).map(tick => tick[name]?.totalUs || 0))),
	]));
	const native = key.startsWith("native/");
	const nativeStepSamples = merge("n4Steps").map(sample => sample[1]);
	const totalMutation = distribution(merge("mutationUs"));
	const authority = distribution(merge("authorityInclusiveUs"));
	const n3EstimatedUsPerCommit = stages.commitInclusiveUs ? (
		stages.commitInclusiveUs.totalUs - authority.total +
		(stages.n3ObserverUs?.totalUs || 0) + (stages.tagN3ObserverUs?.totalUs || 0) -
		(stages.n4CommitUs?.totalUs || 0)
	) / commits : null;
	const heapChanges = cases.map(({ entry }) => {
		const values = entry.raw.heapKiB.map(value => Array.isArray(value) ? value[1] : value);
		let downwardSamples = 0;
		for (let index = 1; index < values.length; index++) if (values[index] < values[index - 1]) downwardSamples++;
		return { minKiB: Math.min(...values), maxKiB: Math.max(...values), startKiB: values[0], endKiB: values.at(-1), downwardSamples };
	});
	summaries.push({
		key, runs: cases.length, commits, mutationUs: totalMutation,
		tickCpuUs: distribution(merge(native ? "tickCpuUs" : "tickUs")),
		n4StepUs: distribution(native ? nativeStepSamples : merge("stepUs")),
		serverHeartbeatMs: native ? distribution(merge("serverHeartbeatMs")) : undefined,
		observedMs: native ? distribution(merge("observedMs")) : undefined,
		workloadLatenessMs: native ? distribution(merge("tickTimes").map((time, index) => Math.max(0, time - (index % 180) / 30) * 1000)) : undefined,
		queueWaitSteps: native ? undefined : distribution(merge("queueWaitSteps")),
		packetBytes: distribution(merge("packetBytes")),
		stageMeanUsPerCommit, stageWorkloadTickUs, n3EstimatedUsPerCommit, heapChanges,
		perRun: cases.map(({ file, entry }) => ({
			file, mutationMedianUs: entry.mutationUs.median,
			n4TotalUs: native ? entry.raw.n4Steps.reduce((sum, sample) => sum + sample[1], 0) : entry.stepUs.total,
			mutationTotalUs: entry.mutationUs.total, drainSteps: entry.drainSteps,
			packets: native ? entry.clients.reduce((sum, client) => sum + client.packets, 0) : entry.packets,
			payloadBytes: native ? entry.clients.reduce((sum, client) => sum + client.bytes, 0) : entry.payloadBytes,
			seconds: entry.seconds, observedP95Ms: entry.observedMs?.p95,
			frameMaxMs: entry.serverHeartbeatMs?.max,
		})),
	});
}
const output = { runs, quantiles: "nearest rank; CPU/native pooled samples; audit per-trial summaries; p95 >= 20, p99 >= 100; no confidence intervals", summaries };
process.stdout.write(JSON.stringify(output, null, 2) + "\n");
