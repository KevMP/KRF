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
		min: sorted[0] ?? 0,
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
const files = fs.readdirSync(directory).filter(file => /^(native(?:-(?:candidate|n9)-c[2468])?|cpu|audit)-run\d+\.json(\.gz)?$/.test(file)).sort();
if (new Set(files.map(file => file.replace(/\.gz$/, ""))).size !== files.length) {
	throw new Error("Duplicate plain/gzip observations would count the same trial twice");
}
if (!files.length) throw new Error(`No local benchmark runs in ${directory}`);
const groups = new Map();
const runs = [];
let nativeHarness;
const nativeImplementations = new Map();
let auditEnvironment;
for (const file of files) {
	const result = load(file);
	if (result.success !== true) throw new Error(`Failed benchmark ${file}`);
	const matrix = /^native-(candidate|n9)-c([2468])-/.exec(file);
	if (matrix) {
		if (result.workloadVersion !== 2 || result.clients !== Number(matrix[2]) || result.cases.length !== 9) {
			throw new Error(`Incomplete native matrix trial: ${file}`);
		}
		const sortedEntries = value => Object.entries(value).sort(([a], [b]) => a.localeCompare(b));
		const signature = JSON.stringify([result.environment.studioFileVersion, sortedEntries(result.environment.harnessSHA256)]);
		if (nativeHarness && nativeHarness !== signature) throw new Error(`Mixed native harness/Studio: ${file}`);
		nativeHarness = signature;
		const source = JSON.stringify(sortedEntries(result.environment.sourceSHA256));
		if (nativeImplementations.has(matrix[1]) && nativeImplementations.get(matrix[1]) !== source) {
			throw new Error(`Mixed native implementation in ${matrix[1]}: ${file}`);
		}
		nativeImplementations.set(matrix[1], source);
	}
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
	runs.push({ file, environment: result.environment, cases: result.cases.length,
		idle: result.idle?.map(entry => ({ ...entry, host: result.hostMeasurements ? summarizeHost(result.hostMeasurements.samples.filter(sample =>
			sample.unixMs >= entry.startedUnixMs && sample.unixMs <= entry.endedUnixMs)) : undefined })),
	});
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
		if (matrix && (entry.recipients !== result.clients || entry.clients.length !== result.clients ||
			new Set(entry.clients.map(client => client.clientId)).size !== result.clients)) {
			throw new Error(`Wrong native recipient identities: ${file}`);
		}
		if (matrix) {
			const hostSamples = result.hostMeasurements?.samples.filter(sample =>
				sample.unixMs >= entry.startedUnixMs && sample.unixMs <= entry.endedUnixMs);
			if (!hostSamples?.length || !hostSamples.some(sample =>
				sample.processes.filter(process => process.role === "client").length === result.clients &&
				sample.processes.filter(process => process.role === "server").length === 1)) {
				throw new Error(`Missing native OS process-count witness: ${file}`);
			}
		}
		const key = [kind, entry.actors, entry.mode, entry.syntheticActionsLobbyWide ?? 0, entry.recipients ?? result.clients ?? 2, entry.diagnostic ?? false,
			...(matrix ? [matrix[1]] : [])].join("/");
		if (!groups.has(key)) groups.set(key, []);
		groups.get(key).push({ file, entry, host: result.hostMeasurements });
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
		workloadLatenessMs: native ? distribution(cases.flatMap(({ entry }) => entry.raw.tickTimes.map((time, index) => Math.max(0, time - index / (entry.hz ?? 30)) * 1000))) : undefined,
		queueWaitSteps: native ? undefined : distribution(merge("queueWaitSteps")),
		packetBytes: distribution(merge("packetBytes")),
		stageMeanUsPerCommit, stageWorkloadTickUs, n3EstimatedUsPerCommit, heapChanges,
		work: merge("work").length ? Object.fromEntries(["connections", "streams", "checks", "prepares", "measurements", "encodes", "sends", "captures", "priorities"].map(unit => [unit, distribution(merge("work").map(sample => sample[unit] || 0))])) : null,
		perRun: cases.map(({ file, entry, host }) => ({
			file, work: entry.raw.work, mutationMedianUs: entry.mutationUs.median,
			n4TotalUs: native ? entry.raw.n4Steps.reduce((sum, sample) => sum + sample[1], 0) : entry.stepUs.total,
			mutationTotalUs: entry.mutationUs.total, drainSteps: entry.drainSteps,
			packets: native ? entry.clients.reduce((sum, client) => sum + client.packets, 0) : entry.packets,
			payloadBytes: native ? entry.clients.reduce((sum, client) => sum + client.bytes, 0) : entry.payloadBytes,
			seconds: entry.seconds, observedP95Ms: entry.observedMs?.p95,
			frameMaxMs: entry.serverHeartbeatMs?.max,
			clients: native ? entry.clients.map(client => ({
				clientId: client.clientId, handlerUs: client.handlerUs,
				observedMs: client.observedMs,
				heartbeatMs: client.heartbeatMs, renderMs: client.renderMs,
				heapKiB: client.rawHeapKiB ? distribution(client.rawHeapKiB) : undefined,
			})) : undefined,
			host: native && host ? summarizeHost(host.samples.filter(sample =>
				sample.unixMs >= entry.startedUnixMs && sample.unixMs <= entry.endedUnixMs)) : undefined,
		})),
	});
}
const output = { runs, quantiles: "nearest rank; CPU/native pooled samples; audit per-trial summaries; p95 >= 20, p99 >= 100; no confidence intervals", summaries };
process.stdout.write(JSON.stringify(output, null, 2) + "\n");

function summarizeHost(samples) {
	const metric = name => distribution(samples.map(sample => sample[name]).filter(Number.isFinite));
	return {
		count: samples.length, hostCpuPercent: metric("hostCpuPercent"), maxLogicalCpuPercent: metric("maxLogicalCpuPercent"),
		availableMiB: metric("availableMiB"), committedPercent: metric("committedPercent"),
		pagesInputPerSec: metric("pagesInputPerSec"), sampleCostMs: metric("sampleCostMs"),
		monitorCpuCores: metric("monitorCpuCores"),
		roles: Object.fromEntries(["server", "client", "launcher", "unknown"].map(role => [role, {
			cpuCores: distribution(samples.map(sample => sample.processes.filter(process => process.role === role).reduce((sum, process) => sum + (process.cpuCores ?? 0), 0))),
			workingSetMiB: distribution(samples.map(sample => sample.processes.filter(process => process.role === role).reduce((sum, process) => sum + process.workingSetMiB, 0))),
			privateMiB: distribution(samples.map(sample => sample.processes.filter(process => process.role === role).reduce((sum, process) => sum + process.privateMiB, 0))),
		} ])),
		processes: [...new Set(samples.flatMap(sample => sample.processes.map(process => process.processId)))].map(processId => {
			const values = samples.flatMap(sample => sample.processes.filter(process => process.processId === processId));
			return { processId, role: values[0].role, instance: values[0].instance,
				cpuCores: distribution(values.map(value => value.cpuCores).filter(Number.isFinite)),
				workingSetMiB: distribution(values.map(value => value.workingSetMiB)),
				privateMiB: distribution(values.map(value => value.privateMiB)),
			};
		}),
		processCpuCores: distribution(samples.map(sample => sample.processes.reduce((sum, process) => sum + (process.cpuCores ?? 0), 0))),
		processWorkingSetMiB: distribution(samples.map(sample => sample.processes.reduce((sum, process) => sum + process.workingSetMiB, 0))),
		processPrivateMiB: distribution(samples.map(sample => sample.processes.reduce((sum, process) => sum + process.privateMiB, 0))),
		maxProcessCount: Math.max(0, ...samples.map(sample => sample.processes.length)),
		minClientProcessCount: samples.length ? Math.min(...samples.map(sample => sample.processes.filter(process => process.role === "client").length)) : null,
		maxClientProcessCount: Math.max(0, ...samples.map(sample => sample.processes.filter(process => process.role === "client").length)),
	};
}
