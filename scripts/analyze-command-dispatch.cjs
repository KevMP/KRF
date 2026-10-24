// Rebuild equivalent command workload comparisons from ignored local evidence.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const directory = process.argv[2] || "build/command-comparison";
const pattern = /^(before|after)-(cpu|native)(?:-c([2468]))?-run\d+\.json(\.gz)?$/;
const files = fs.readdirSync(directory).filter(file => pattern.test(file)).sort();
if (!files.length) throw Error("No command comparison files");
if (new Set(files.map(file => file.replace(/\.gz$/, ""))).size !== files.length) throw Error("Duplicate plain/gzip trial");
const canonical = value => JSON.stringify(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));
function distribution(values) {
	const sorted = values.toSorted((a, b) => a - b);
	const at = probability => sorted[Math.max(0, Math.ceil(sorted.length * probability) - 1)] ?? 0;
	return { count: sorted.length, median: at(.5), p95: sorted.length >= 20 ? at(.95) : null,
		p99: sorted.length >= 100 ? at(.99) : null, max: sorted.at(-1) ?? 0,
		total: sorted.reduce((sum, value) => sum + value, 0) };
}
const signatures = new Map();
const implementations = new Map();
const groups = new Map();
const runs = [];
for (const file of files) {
	const [, arm, profile, clients] = pattern.exec(file);
	const bytes = fs.readFileSync(path.join(directory, file));
	const result = JSON.parse((file.endsWith(".gz") ? zlib.gunzipSync(bytes) : bytes).toString("utf8").replace(/^\uFEFF/, ""));
	if (result.success !== true || result.workloadVersion !== 1 ||
		result.profile !== (profile === "cpu" ? "CommandsCPU" : "CommandsNative")) throw Error(`Wrong/failed workload: ${file}`);
	if (profile === "native" && (result.clients !== Number(clients) || result.cases.length !== 3)) throw Error(`Wrong native count: ${file}`);
	if (profile === "cpu" && result.cases.length !== 9) throw Error(`Incomplete CPU trial: ${file}`);
	const environment = result.environment;
	if (arm === "before" && environment?.implementationRevision !== "a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a") throw Error(`Unpinned N9: ${file}`);
	if (!environment?.harnessSHA256 || !environment?.sourceSHA256) throw Error(`Missing provenance: ${file}`);
	const signature = JSON.stringify([result.workloadVersion, environment.studioFileVersion, canonical(environment.harnessSHA256),
		profile === "cpu" ? canonical(environment.workloadSourcesSHA256 ?? {}) : null,
		profile === "cpu" ? environment.workloadSHA256 : null]);
	if (signatures.has(profile) && signatures.get(profile) !== signature) throw Error(`Mixed harness/Studio: ${file}`);
	signatures.set(profile, signature);
	const source = canonical(environment.sourceSHA256);
	if (implementations.has(arm) && implementations.get(arm) !== source) throw Error(`Mixed implementation: ${file}`);
	implementations.set(arm, source);
	runs.push({ file, environment });
	for (const entry of result.cases) {
		if (profile === "native" && (entry.recipients !== result.clients || entry.clients.length !== result.clients ||
			new Set(entry.clients.map(client => client.clientId)).size !== result.clients)) throw Error(`Incomplete client reports: ${file}`);
		if (arm === "after" && (entry.handlersOnIngress !== 0 || entry.admitted !== entry.executed ||
			entry.dispatchesPerPump.max > 16 || entry.visitsPerPump.max > 64 || entry.peakPending > 256 || entry.peakPendingBytes > 524288 ||
			entry.maxOtherDispatchesWhileEligibleHead >= entry.recipients)) throw Error(`Command bound/fairness violation: ${file}`);
		const key = [profile, entry.recipients, entry.mode].join("/");
		if (!groups.has(key)) groups.set(key, { before: [], after: [] });
		const host = result.hostMeasurements?.samples.filter(sample => sample.unixMs >= entry.startedUnixMs && sample.unixMs <= entry.endedUnixMs);
		if (profile === "native" && !host?.some(sample => sample.processes.filter(process => process.role === "client").length === result.clients &&
			sample.processes.filter(process => process.role === "server").length === 1)) throw Error(`Missing native process witness: ${file}`);
		groups.get(key)[arm].push({ file, ...entry, host: host ? summarizeHost(host) : undefined });
	}
}
function summarizeHost(samples) {
	return {
		count: samples.length,
		cpuPercent: distribution(samples.map(sample => sample.hostCpuPercent)),
		availableMiBMin: Math.min(...samples.map(sample => sample.availableMiB)),
		committedPercentMax: Math.max(...samples.map(sample => sample.committedPercent)),
		roles: Object.fromEntries(["server", "client", "launcher"].map(role => [role, {
			cpuCores: distribution(samples.map(sample => sample.processes.filter(process => process.role === role)
				.reduce((sum, process) => sum + (process.cpuCores ?? 0), 0))),
			workingSetMiB: distribution(samples.map(sample => sample.processes.filter(process => process.role === role)
				.reduce((sum, process) => sum + process.workingSetMiB, 0))),
		}])),
	};
}
function summarize(cases) {
	if (!cases.length) return null;
	const raw = name => cases.flatMap(entry => entry.raw[name] || []);
	const offered = cases.reduce((sum, entry) => sum + entry.offered, 0);
	const executed = cases.reduce((sum, entry) => sum + entry.executed, 0);
	return {
		trials: cases.length, offered, admitted: cases.reduce((sum, entry) => sum + entry.admitted, 0), executed,
		ingressUs: distribution(raw("ingressUs")), dispatchUs: distribution(raw("dispatchUs")),
		egressUs: distribution(raw("egressUs")), handlerUs: distribution(raw("handlerUs")),
		dispatchWaitPumps: distribution(raw("dispatchWaitPumps")), resultWaitPumps: distribution(raw("resultWaitPumps")),
		dispatchWaitMs: distribution(raw("dispatchWaitMs")),
		clientResultMs: distribution(cases.flatMap(entry => entry.clients?.flatMap(client => client.raw.resultMs) || [])),
		perRun: cases.map(({ raw, ...entry }) => ({ ...entry,
			ingressPlusDispatchUsPerOffered: (entry.ingressUs.total + entry.dispatchUs.total) / entry.offered,
			clients: entry.clients?.map(({ raw, ...client }) => client),
		})),
	};
}
const summaries = [...groups].map(([key, value]) => {
	const offered = [...value.before, ...value.after].map(entry => entry.offered);
	if (new Set(offered).size !== 1) throw Error(`Offered workloads differ: ${key}`);
	return { key, before: summarize(value.before), after: summarize(value.after) };
});
process.stdout.write(JSON.stringify({ runs,
	quantiles: "nearest rank; pooled raw samples within implementation/profile/count/mode; per-trial values retained; p95 >=20, p99 >=100; no timing gates",
	summaries }, null, 2) + "\n");
