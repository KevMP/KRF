// Thin comparison orchestration over the existing Studio launchers/analyzers.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const root = path.resolve(__dirname, "..");
// A Node child of PowerShell 7 otherwise passes its incompatible module paths
// into Windows PowerShell 5. Let that host construct its own standard paths.
const powershellEnvironment = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.toLowerCase() !== "psmodulepath"));
const N9 = "a9f1d7bcaa822e3b2ee0b6180f326bd2a95efc2a";
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex").toUpperCase();
const toolHashes = () => Object.fromEntries(["compare-networking.cjs", "analyze-command-dispatch.cjs", "analyze-networking-baseline.cjs"].map(file => [file, hash(path.join(__dirname, file))]));
const canonical = value => JSON.stringify(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));
const read = file => JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
const save = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");

function options(args) {
	const values = {};
	for (let index = 0; index < args.length; index++) {
		const key = args[index];
		if (["--help", "--full"].includes(key)) { values[key.slice(2)] = true; continue; }
		if (!["--workload", "--profile", "--reference", "--clients", "--repetitions", "--studio", "--analyze", "--records", "--bytes", "--focus", "--candidate-records"].includes(key)) throw Error(`Unknown option: ${key}`);
		if (index + 1 >= args.length || args[index + 1].startsWith("--")) throw Error(`Missing value: ${key}`);
		values[key.slice(2)] = args[++index];
	}
	const result = {
		workload: (values.workload || "commands").toLowerCase(), profile: (values.profile || (values.full ? "both" : "cpu")).toLowerCase(),
		reference: values.reference || N9, clients: (values.clients || (values.full ? "2,4,6,8" : "2")).split(",").map(Number),
		repetitions: Number(values.repetitions || (values.full ? 2 : 1)), studio: values.studio,
		help: values.help, analyze: values.analyze,
		records: Number(values.records || 64), candidateRecords: Number(values["candidate-records"] || values.records || 64), bytes: Number(values.bytes || 32768), focus: values.focus || "full",
	};
	if (!["commands", "publication", "audit"].includes(result.workload)) throw Error("--workload must be commands, publication or audit");
	if (!["cpu", "native", "both"].includes(result.profile)) throw Error("--profile must be cpu, native or both");
	if (!Number.isInteger(result.repetitions) || result.repetitions < 1 || result.repetitions > 10) throw Error("--repetitions must be 1..10");
	if (!result.clients.length || new Set(result.clients).size !== result.clients.length || result.clients.some(n => ![2, 4, 6, 8].includes(n))) throw Error("--clients must contain unique counts from 2,4,6,8");
	if (result.workload === "audit" && result.profile !== "cpu") throw Error("audit supports --profile cpu only");
	if (![result.records, result.candidateRecords].every(value => Number.isInteger(value) && value >= 1 && value <= 4096) || !Number.isInteger(result.bytes) || result.bytes < 1024 || result.bytes > 4194304) throw Error("Invalid --records/--candidate-records (1..4096) or --bytes (1024..4194304)");
	if (!["full", "scheduler"].includes(result.focus) || result.focus !== "full" && (result.workload !== "publication" || result.profile !== "cpu")) throw Error("--focus scheduler requires --workload publication --profile cpu");
	return result;
}

function plan(config) {
	const profiles = [
		...(config.profile !== "native" ? [{ profile: "cpu", clients: null }] : []),
		...(config.profile !== "cpu" ? config.clients.map(clients => ({ profile: "native", clients })) : []),
	];
	return profiles.flatMap((entry, index) => Array.from({ length: config.repetitions }, (_, repetition) => {
		const arms = (index + repetition) % 2 === 0 ? ["before", "after"] : ["after", "before"];
		return arms.map(arm => ({ ...entry, arm, repetition: repetition + 1,
			id: `${arm}-${entry.profile}${entry.clients ? `-c${entry.clients}` : ""}-run${repetition + 1}`, status: "pending" }));
	}).flat());
}

function resolveRevision(ref) {
	const result = spawnSync("git", ["-c", `safe.directory=${root.replaceAll("\\", "/")}`, "rev-parse", "--verify", `${ref}^{commit}`], { cwd: root, encoding: "utf8" });
	if (result.status !== 0 || !/^[a-f0-9]{40}$/i.test(result.stdout.trim())) throw Error(`Cannot resolve commit: ${ref}`);
	return result.stdout.trim();
}

function sourceHashes() {
	const output = {};
	function walk(directory) {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const file = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(file);
			else if (entry.name.endsWith(".luau")) output[path.relative(root, file).replaceAll("\\", "/")] = hash(file);
		}
	}
	walk(path.join(root, "src"));
	return output;
}

function destination(config, trial) {
	if (config.workload === "audit") return `raw/audit/${trial.arm}/audit-run${trial.repetition}.json`;
	if (config.workload === "commands") return `raw/commands/${trial.id}.json`;
	if (trial.profile === "native") return `raw/publication/native-${trial.arm === "before" ? "n9" : "candidate"}-c${trial.clients}-run${trial.repetition}.json`;
	return `raw/publication/cpu-${trial.arm}/cpu-run${trial.repetition}.json`;
}

function contained(directory, relative) {
	const file = path.resolve(directory, relative);
	if (!file.startsWith(path.resolve(directory) + path.sep)) throw Error("Artifact path escapes comparison directory");
	return file;
}

function verify(directory, manifest, partial = false) {
	const expected = plan(manifest.config);
	if (expected.length !== manifest.trials.length || expected.some((entry, index) =>
		["id", "profile", "clients", "arm", "repetition"].some(key => entry[key] !== manifest.trials[index][key]))) throw Error("Incomplete or changed trial plan");
	const signatures = new Map();
	const sources = new Map();
	const observations = new Set();
	for (const trial of manifest.trials) {
		if (partial && trial.status === "pending") continue;
		if (trial.status !== "complete" || !trial.result) throw Error(`Incomplete trial: ${trial.id}`);
		if (trial.result !== destination(manifest.config, trial) || !trial.originalDirectory || observations.has(trial.originalDirectory)) throw Error(`Duplicate/misnamed observation: ${trial.id}`);
		observations.add(trial.originalDirectory);
		const file = contained(directory, trial.result);
		if (hash(file) !== trial.resultSHA256) throw Error(`Artifact changed: ${trial.id}`);
		const result = read(file), environment = result.environment;
		if (result.success !== true || !environment?.sourceSHA256 || !environment?.harnessSHA256) throw Error(`Failed/missing provenance: ${trial.id}`);
		if (environment.implementationRevision !== (trial.arm === "before" ? manifest.referenceRevision : manifest.candidateRevision)) throw Error(`Wrong implementation revision: ${trial.id}`);
		if (environment.harnessRevision !== manifest.candidateRevision) throw Error(`Wrong harness revision: ${trial.id}`);
		if (environment.studioFileVersion !== manifest.studioFileVersion) throw Error(`Mixed Studio: ${trial.id}`);
		if (canonical(environment.schedulerBudget || { records: 64, bytes: 32768 }) !== canonical({ records: trial.arm === "after" ? manifest.config.candidateRecords ?? manifest.config.records ?? 64 : manifest.config.records ?? 64, bytes: manifest.config.bytes ?? 32768 })) throw Error(`Wrong scheduler budget: ${trial.id}`);
		const focus = manifest.config.focus ?? "full";
		if ((environment.benchmarkFocus ?? "full") !== focus) throw Error(`Wrong benchmark focus: ${trial.id}`);
		if (focus === "scheduler" && (result.benchmarkFocus !== focus || result.cases?.length !== 12 ||
			new Set(result.cases.map(entry => [entry.mode, entry.recipients, entry.syntheticActionsLobbyWide].join("/"))).size !== 12 ||
			result.cases.some(entry => entry.actors !== 90 || ![2, 30].includes(entry.recipients) || ![0, 40].includes(entry.syntheticActionsLobbyWide) || entry.diagnostic !== false || !["Ordinary", "Heavy", "Burst"].includes(entry.mode)))) throw Error(`Incomplete scheduler focus: ${trial.id}`);
		const source = canonical(environment.sourceSHA256);
		if (sources.has(trial.arm) && sources.get(trial.arm) !== source) throw Error(`Mixed ${trial.arm} source: ${trial.id}`);
		sources.set(trial.arm, source);
		if (trial.arm === "after" && source !== canonical(manifest.candidateSourceSHA256)) throw Error(`Candidate source differs: ${trial.id}`);
		const common = canonical(environment.harnessSHA256);
		if (signatures.has("harness") && signatures.get("harness") !== common) throw Error(`Mixed harness: ${trial.id}`);
		signatures.set("harness", common);
		const workload = JSON.stringify([result.workloadVersion ?? null, environment.workloadSHA256 ?? null,
			environment.workloadSourcesSHA256 ? canonical(environment.workloadSourcesSHA256) : null]);
		if (signatures.has(trial.profile) && signatures.get(trial.profile) !== workload) throw Error(`Mixed ${trial.profile} workload: ${trial.id}`);
		signatures.set(trial.profile, workload);
		if (trial.profile === "native" && result.clients !== trial.clients) throw Error(`Wrong actual client count: ${trial.id}`);
	}
}

function capture(command, args, log) {
	return new Promise((resolve, reject) => {
		const stream = fs.createWriteStream(log);
		const child = spawn(command, args, { cwd: root, windowsHide: true, shell: false, env: powershellEnvironment });
		let output = "";
		for (const name of ["stdout", "stderr"]) child[name].on("data", bytes => { output += bytes.toString(); stream.write(bytes); process[name].write(bytes); });
		child.on("error", error => { stream.end(); reject(error); });
		child.on("close", code => { stream.end(); code === 0 ? resolve(output) : reject(Error(`Launcher exit ${code}; inspect ${log}`)); });
	});
}

function analyze(directory, manifest) {
	verify(directory, manifest);
	const outputs = {};
	function run(name, script, args) {
		const file = path.join(directory, `analysis-${name}.json`);
		const fd = fs.openSync(file, "w");
		const result = spawnSync(process.execPath, [path.join(__dirname, script), ...args], { cwd: root, stdio: ["ignore", fd, "pipe"], encoding: "utf8" });
		fs.closeSync(fd);
		if (result.status !== 0) throw Error(`Analyzer failed (${name}): ${result.stderr}`);
		outputs[name] = read(file);
	}
	if (manifest.config.workload === "audit") {
		for (const arm of ["before", "after"]) run(`audit-${arm}`, "analyze-networking-baseline.cjs", [path.join(directory, `raw/audit/${arm}`)]);
	}
	else if (manifest.config.workload === "commands") run("commands", "analyze-command-dispatch.cjs", [path.join(directory, "raw/commands"), manifest.referenceRevision]);
	else {
		if (manifest.config.profile !== "cpu") run("publication-native", "analyze-networking-baseline.cjs", [path.join(directory, "raw/publication")]);
		if (manifest.config.profile !== "native") for (const arm of ["before", "after"]) run(`publication-cpu-${arm}`, "analyze-networking-baseline.cjs", [path.join(directory, `raw/publication/cpu-${arm}`)]);
	}
	return outputs;
}

function distribution(values) {
	const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
	const q = p => sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? null;
	return { count: sorted.length, median: q(.5), p95: sorted.length >= 20 ? q(.95) : null, p99: sorted.length >= 100 ? q(.99) : null, max: sorted.at(-1) ?? null, total: sorted.reduce((a, b) => a + b, 0) };
}
const max = (runs, key) => Math.max(0, ...runs.map(run => run[key] || 0));
const range = values => { values = values.filter(Number.isFinite); return values.length ? [Math.min(...values), Math.max(...values)] : null; };
function normalize(outputs) {
	if (outputs.commands) return outputs.commands.summaries.map(entry => ({ key: entry.key, kind: "commands",
		...Object.fromEntries(["before", "after"].map(arm => {
			const value = entry[arm];
			if (!value) throw Error(`Missing comparison arm: ${entry.key}`);
			return [arm, {
				pumpUs: value.egressUs, physicalSends: value.perRun.reduce((sum, run) => sum + (run.physicalSends ?? run.packets ?? 0), 0),
				trials: value.trials, offered: value.offered, admitted: value.admitted, executed: value.executed,
				wireOffered: value.perRun.reduce((sum, run) => sum + (run.wireOffered ?? run.offered), 0),
				localRefused: value.perRun.reduce((sum, run) => sum + (run.localRefused ?? 0), 0),
				costUs: (value.ingressUs.total + value.dispatchUs.total) / value.offered,
				latency: entry.key.startsWith("native") ? value.clientResultMs : value.resultWaitPumps,
				latencyUnit: entry.key.startsWith("native") ? "ms" : "virtual pumps",
				dispatchWait: entry.key.startsWith("native") ? value.dispatchWaitMs : value.dispatchWaitPumps,
				peakPending: max(value.perRun, "peakPending"), peakPendingBytes: max(value.perRun, "peakPendingBytes"),
				serverCores: range(value.perRun.map(run => run.host?.roles.server.cpuCores.median)),
				clientCores: range(value.perRun.map(run => run.host?.roles.client.cpuCores.median)),
				hostCpuPercent: range(value.perRun.map(run => run.host?.cpuPercent.median)),
				perRun: value.perRun,
			}];
		})),
	}));
	if (outputs["audit-before"]) {
		const cases = new Map();
		for (const arm of ["before", "after"]) for (const entry of outputs[`audit-${arm}`].summaries) {
			if (!cases.has(entry.key)) cases.set(entry.key, { key: entry.key, kind: "audit",
				comparisonScope: entry.key.includes("/Collector/") ? "N10-only collector experiment; N9 requested-on control has no collector" : "paired implementation" });
			const runs = entry.perRun;
			const pumps = runs.flatMap(run => run.raw?.pumpUs || (Number.isFinite(run.pumpUs) ? [run.pumpUs] : []));
			const waits = runs.flatMap(run => run.raw?.waits || []);
			cases.get(entry.key)[arm] = { trials: entry.runs, commits: null, perRun: runs,
				costUs: distribution(pumps).p95 ?? distribution(pumps).median,
				pumpUs: distribution(pumps), latency: distribution(waits), latencyUnit: "virtual pumps",
				peakPending: max(runs, "peakPendingRecords"), peakPendingBytes: max(runs, "peakPendingBytes") };
		}
		for (const entry of cases.values()) {
			if (!entry.before || !entry.after) throw Error(`Missing audit arm: ${entry.key}`);
			if (JSON.stringify(entry.before.perRun.map(run => run.perActorOffered)) !== JSON.stringify(entry.after.perRun.map(run => run.perActorOffered))) throw Error(`Unequal audit offered work: ${entry.key}`);
		}
		return [...cases.values()];
	}
	const cases = new Map();
	for (const [name, output] of Object.entries(outputs)) for (const entry of output.summaries) {
		const parts = entry.key.split("/");
		const arm = name.endsWith("-before") ? "before" : name.endsWith("-after") ? "after" : parts.pop() === "n9" ? "before" : "after";
		const key = parts.join("/");
		if (!cases.has(key)) cases.set(key, { key, kind: "publication" });
		cases.get(key)[arm] = {
			trials: entry.runs, commits: entry.commits, costUs: entry.n4StepUs.p95, pumpUs: entry.n4StepUs,
			work: entry.work, physicalSends: entry.perRun.reduce((sum, run) => sum + run.packets, 0),
			latency: entry.observedMs || entry.queueWaitSteps, latencyUnit: key.startsWith("native") ? "ms" : "virtual pumps",
			peakPending: null, peakPendingBytes: null,
			serverCores: range(entry.perRun.map(run => run.host?.roles.server.cpuCores.median)),
			clientCores: range(entry.perRun.map(run => run.host?.roles.client.cpuCores.median)),
			hostCpuPercent: range(entry.perRun.map(run => run.host?.hostCpuPercent.median)), perRun: entry.perRun,
		};
	}
	for (const entry of cases.values()) if (!entry.before || !entry.after || entry.before.commits !== entry.after.commits) throw Error(`Unequal publication workloads: ${entry.key}`);
	return [...cases.values()];
}

const fmt = value => Number.isFinite(value) ? value.toFixed(2) : "—";
const quantiles = value => [value?.median, value?.p95, value?.p99].map(fmt).join(" / ");
const span = values => values ? values.map(fmt).join("–") : "—";
function report(manifest, cases) {
	const regressions = [];
	const lines = ["# Networking comparison", "", `Correctness: **PASS** (${manifest.trials.length} planned/completed trials).`, "",
		`Reference: \`${manifest.referenceRevision}\`; candidate/harness: \`${manifest.candidateRevision}\`. Source hashes (including dirty work), workload hashes and Studio \`${manifest.studioFileVersion}\` verified across the planned trials.`, "",
		"Arrows are reference → candidate. Counts sum trials. Native offered counts include public Send calls; wire counts exclude local refusals. Command cost is elapsed ingress+dispatch µs/offered request; publication cost is pump p95 µs. CPU-profile waits are virtual pumps, not wall time. Native latency spans public Send→result (commands) or mutation→notification (publication), not RTT. Quantiles pool raw samples per arm/case; p95 needs 20, p99 needs 100 samples. CPU ranges are per-trial medians of logical cores; client CPU sums all client processes. No confidence interval or timing pass/fail gate is inferred.", "",
		"| Case | Offered / wire / admitted / executed (or commits) | Cost µs | Result/observation p50 / p95 / p99 | Peak pending jobs / bytes | Server / client CPU cores |", "| --- | --- | --- | --- | --- | --- |"];
	for (const entry of cases) {
		const { before, after } = entry;
		const counts = value => entry.kind === "commands" ? `${value.offered}/${value.wireOffered ?? value.offered}/${value.admitted}/${value.executed}` : entry.kind === "audit" ? `${value.perRun.reduce((sum, run) => sum + (run.logicalRecords || 0), 0)} records` : `${value.commits} commits`;
		lines.push(`| ${entry.key}${entry.comparisonScope?.startsWith("N10-only") ? " (N10-only control)" : ""} | ${counts(before)} → ${counts(after)} | ${fmt(before.costUs)} → ${fmt(after.costUs)} | ${quantiles(before.latency)} → ${quantiles(after.latency)} ${after.latencyUnit} | ${before.peakPending ?? "—"}/${before.peakPendingBytes ?? "—"} → ${after.peakPending ?? "—"}/${after.peakPendingBytes ?? "—"} | ${span(before.serverCores)} / ${span(before.clientCores)} → ${span(after.serverCores)} / ${span(after.clientCores)} |`);
		for (const [metric, b, a] of [["costUs", before.costUs, after.costUs], ["latencyP95", before.latency?.p95, after.latency?.p95]]) if (Number.isFinite(b) && Number.isFinite(a) && a > b) regressions.push({ case: entry.key, metric, reference: b, candidate: a, delta: a - b, percent: b ? (a / b - 1) * 100 : null,
			equalExecutions: entry.kind === "commands" ? before.executed === after.executed : null, equalCommits: entry.kind === "publication" ? before.commits === after.commits : null });
	}
	lines.push("", "## Scheduler work", "", `Fixture budget: reference ${manifest.config.records ?? 64} -> candidate ${manifest.config.candidateRecords ?? manifest.config.records ?? 64} logical records, ${manifest.config.bytes ?? 32768} bytes per pump; focus ${manifest.config.focus ?? "full"}. ${(manifest.config.candidateRecords ?? manifest.config.records ?? 64) === (manifest.config.records ?? 64) ? "Equal-configuration comparison." : "CONFIGURATION EXPERIMENT: record capacity differs; gains cannot be attributed solely to scheduler implementation."} Work counters are candidate internal attempted-work accounting; legacy counts are retained separately in audit probes. Audit pending inspections occur outside the pump timer. No unmeasured legacy counter is treated as zero.`, "", "| Case | Arm | Pump p50 / p95 / p99 µs | Physical sends |", "| --- | --- | --- | --- |");
	for (const entry of cases) for (const arm of ["before", "after"]) if (entry[arm].pumpUs) lines.push(`| ${entry.key} | ${arm} | ${quantiles(entry[arm].pumpUs)} | ${entry[arm].physicalSends ?? entry[arm].perRun.reduce((sum, run) => sum + (run.physicalSends || 0), 0)} |`);
	lines.push("", "## Observed increases and comparison limits", "", "Reduced execution from shedding is not throughput improvement. More completed work is also not an equal-work cost comparison. Region timers include probes, engine scheduling and GC; OS counters include engine/host overhead and have coarse sampling. Publication admission is not applicable. Every higher observed cost/p95 below is retained even when correctness passes; short/noisy trials do not establish causation.", "");
	for (const item of regressions) lines.push(`- ${item.case}: ${item.metric} ${fmt(item.reference)} → ${fmt(item.candidate)} (${fmt(item.percent)}%); ${item.equalCommits ? "equal commit counts" : item.equalExecutions ? "equal executed counts" : "executed work differs"}.`);
	if (!regressions.length) lines.push("No higher cost/p95 observations in these trials; this is not proof of no regression.");
	if (manifest.config.workload === "commands") {
		lines.push("", "## Per-client admission and execution", "", "One row per case/arm/trial/client; plan indices, rather than unstable Player IDs, identify workload roles. Per-window wire-offered/admitted counts are retained in comparison.json.", "", "| Case | Arm / trial | Client | Offered / wire / admitted / executed | First-burst admitted | Result p50 / p95 / p99 ms |", "| --- | --- | --- | --- | --- | --- |");
		for (const entry of cases) for (const arm of ["before", "after"]) for (const run of entry[arm].perRun) for (const client of run.clients || run.perClient || []) lines.push(`| ${entry.key} | ${arm} / ${run.file} | ${client.planIndex ?? client.client} | ${client.offered ?? "—"}/${client.wireOffered ?? client.offered ?? "—"}/${client.admitted ?? "—"}/${client.executed ?? client.results} | ${client.firstTickAdmitted ?? "—"} | ${client.resultMs ? quantiles(client.resultMs) : "—"} |`);
	}
	lines.push("", "## Per-trial host pressure", "", "Only timed workload-window samples are included; startup is separate in raw host records. Native process CPU is not isolated KRF CPU, and collection has one-second targets plus lag.", "", "| Case | Arm / trial | Host CPU median / max % | Available RAM min MiB / commit max % |", "| --- | --- | --- | --- |");
	for (const entry of cases) for (const arm of ["before", "after"]) for (const run of entry[arm].perRun) if (run.host) {
		const h = run.host, cpu = h.cpuPercent || h.hostCpuPercent;
		lines.push(`| ${entry.key} | ${arm} / ${run.file} | ${fmt(cpu.median)} / ${fmt(cpu.max)} | ${fmt(h.availableMiBMin ?? h.availableMiB?.min)} / ${fmt(h.committedPercentMax ?? h.committedPercent?.max)} |`);
	}
	lines.push("", "Raw copies, launcher logs, analysis JSON and manifest.json are adjacent to this report. The manifest links original frozen run directories. Failures are terminal and never silently omitted. Rebuild with npm run bench:networking:compare -- --analyze <this-directory>. Full workload definitions and timing boundaries remain in tests/benchmarks/README.md.", "");
	return { markdown: lines.join("\n"), regressions };
}

function summarize(directory, manifest) {
	const outputs = analyze(directory, manifest), cases = normalize(outputs), rendered = report(manifest, cases);
	save(path.join(directory, "comparison.json"), { status: "passed", referenceRevision: manifest.referenceRevision, candidateRevision: manifest.candidateRevision,
		config: manifest.config, configurationExperiment: (manifest.config.candidateRecords ?? manifest.config.records ?? 64) !== (manifest.config.records ?? 64), analysisToolSHA256: toolHashes(), quantiles: "nearest rank; p95 >=20 / p99 >=100; pooled raw samples; CPU ranges are per-trial medians", cases, regressions: rendered.regressions });
	fs.writeFileSync(path.join(directory, "comparison.md"), rendered.markdown);
	return cases;
}

async function main(args) {
	const config = options(args);
	if (config.help) { console.log("npm run bench:networking:compare -- [--workload commands|publication|audit] [--profile cpu|native|both] [--reference <commit>] [--clients 2,4,6,8] [--repetitions 1..10] [--studio <exe>] [--records 64] [--candidate-records <count>] [--bytes 32768] [--focus full|scheduler] [--full] [--analyze <directory>]\nDefault: commands, CPU, N9, one pair. --full: both profiles, 2/4/6/8 native clients, two repetitions."); return; }
	if (config.analyze) {
		const directory = path.resolve(config.analyze), manifest = read(path.join(directory, "manifest.json"));
		try {
			summarize(directory, manifest); console.log(`Verified comparison: ${path.join(directory, "comparison.md")}`);
		} catch (error) {
			save(path.join(directory, "comparison.json"), { status: "failed", failure: String(error) });
			fs.writeFileSync(path.join(directory, "comparison.md"), `# Networking comparison FAILED\n\n${error}\n\nNo complete comparison is claimed.\n`);
			throw error;
		}
		return;
	}
	const directory = path.join(root, "build/networking-comparisons", `${new Date().toISOString().replaceAll(/[:.]/g, "-")}-${crypto.randomUUID().slice(0, 8)}`);
	fs.mkdirSync(directory, { recursive: true });
	const manifest = { version: 1, status: "running", config, referenceRevision: resolveRevision(config.reference), candidateRevision: resolveRevision("HEAD"),
		candidateSourceSHA256: sourceHashes(), workflowSHA256: hash(__filename), toolSHA256: toolHashes(), trials: plan(config), startedAt: new Date().toISOString() };
	const manifestFile = path.join(directory, "manifest.json");
	save(manifestFile, manifest);
	try {
		const studio = config.studio || spawnSync("powershell", ["-NoProfile", "-Command", "$v = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Roblox/Versions') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'RobloxStudioBeta.exe') } | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if (-not $v) { throw 'Studio not found; use --studio' }; Write-Output (Join-Path $v.FullName 'RobloxStudioBeta.exe')"], { encoding: "utf8", windowsHide: true, env: powershellEnvironment }).stdout?.trim();
		if (!studio || !fs.existsSync(studio)) throw Error("Studio executable unavailable; supply --studio");
		manifest.studioPath = path.resolve(studio); manifest.studioSHA256 = hash(studio);
		console.log(`Comparison artifacts: ${directory}`);
		for (const trial of manifest.trials) {
			trial.status = "running"; trial.startedAt = new Date().toISOString(); save(manifestFile, manifest);
			console.log(`START ${trial.id}`);
			const script = trial.profile === "cpu" ? "scripts/measure-networking-baseline.ps1" : "scripts/test-networking-baseline.ps1";
			const workload = config.workload === "audit" ? "Audit" : config.workload === "commands" ? "Commands" : trial.profile === "cpu" ? "Networking" : "Publication";
			const parameters = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Workload", workload, "-StudioPath", manifest.studioPath, "-Records", String(trial.arm === "after" ? config.candidateRecords : config.records), "-Bytes", String(config.bytes)];
			if (trial.profile === "cpu") parameters.push("-Focus", config.focus);
			if (trial.clients) parameters.push("-ClientCount", String(trial.clients));
			if (trial.arm === "before") parameters.push("-ImplementationRevision", manifest.referenceRevision);
			const output = await capture("powershell", parameters, path.join(directory, `${trial.id}.log`));
			const match = /^__KRF_(?:NETWORKING_CPU|NATIVE_NETWORKING_BASELINE)_PASS__ Results: (.+)\r?$/m.exec(output);
			if (!match) throw Error(`No verified pass marker: ${trial.id}`);
			trial.originalDirectory = match[1].trim(); trial.result = destination(config, trial);
			const file = contained(directory, trial.result); fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.copyFileSync(path.join(trial.originalDirectory, "result.json"), file);
			const result = read(file); manifest.studioFileVersion ??= result.environment?.studioFileVersion;
			if (canonical(sourceHashes()) !== canonical(manifest.candidateSourceSHA256) || canonical(toolHashes()) !== canonical(manifest.toolSHA256) || hash(studio) !== manifest.studioSHA256) throw Error("Source/workflow/Studio changed during comparison");
			for (const [relative, digest] of Object.entries(result.environment?.harnessSHA256 || {})) if (hash(path.join(root, relative)) !== digest) throw Error(`Harness changed during launch: ${relative}`);
			trial.resultSHA256 = hash(file); trial.status = "complete"; trial.completedAt = new Date().toISOString();
			verify(directory, manifest, true);
			save(manifestFile, manifest);
		}
		summarize(directory, manifest);
		manifest.status = "passed"; manifest.completedAt = new Date().toISOString(); save(manifestFile, manifest);
		console.log(`PASS: ${path.join(directory, "comparison.md")}`);
	} catch (error) {
		manifest.status = "failed"; manifest.failure = String(error); manifest.completedAt = new Date().toISOString();
		const running = manifest.trials.find(trial => trial.status === "running"); if (running) { running.status = "failed"; running.failure = String(error); }
		save(manifestFile, manifest);
		save(path.join(directory, "comparison.json"), { status: "failed", failure: String(error), trials: manifest.trials });
		fs.writeFileSync(path.join(directory, "comparison.md"), `# Networking comparison FAILED\n\n${error}\n\nNo complete comparison is claimed. Inspect manifest.json and trial logs; failed/pending trials have not been excluded.\n`);
		throw error;
	}
}

module.exports = { options, plan, destination, verify, normalize, report, contained };
if (require.main === module) main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
