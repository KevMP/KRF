const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { options, plan, destination, verify, contained, report, normalize } = require("./compare-networking.cjs");
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex").toUpperCase();

test("default is one quick CPU pair; full matrix is explicit and alternates arms", () => {
	const quick = options([]);
	assert.equal(quick.profile, "cpu");
	assert.equal(plan(quick).length, 2);
	const full = plan(options(["--full"]));
	assert.equal(full.length, 20);
	assert.deepEqual(full.slice(0, 4).map(trial => trial.arm), ["before", "after", "after", "before"]);
	assert.deepEqual([...new Set(full.filter(trial => trial.profile === "native").map(trial => trial.clients))], [2, 4, 6, 8]);
});

test("invalid or ambiguous CLI inputs fail before launching Studio", () => {
	for (const args of [["--clients", "2,2"], ["--clients", "3"], ["--repetitions", "0"], ["--repetitions", "1.5"], ["--profile", "cloud"], ["--reference"], ["--unknown"]]) assert.throws(() => options(args));
	assert.equal(options(["--reference", "HEAD~1", "--profile", "native", "--clients", "8", "--repetitions", "3"]).repetitions, 3);
});

test("budget experiments apply one validated configuration to both arms", () => {
	const config = options(["--workload", "audit", "--records", "128", "--bytes", "65536", "--repetitions", "2"]);
	assert.equal(config.records, 128);
	assert.equal(config.bytes, 65536);
	assert.equal(plan(config).length, 4);
	assert.equal(destination(config, plan(config)[0]), "raw/audit/before/audit-run1.json");
	for (const args of [["--records", "0"], ["--records", "1.5"], ["--bytes", "100"], ["--workload", "audit", "--profile", "native"]]) assert.throws(() => options(args));
});

test("audit comparisons pool raw observations and preserve unpooled legacy counters", () => {
	const entry = { key: "audit/Scene/16/8/HotQuiet/true", runs: 1, perRun: [{ raw: { pumpUs: Array(120).fill(5), waits: Array(120).fill(2) }, probes: { eligibilityChecks: 80 }, logicalRecords: 30 }] };
	const cases = normalize({ "audit-before": { summaries: [entry] }, "audit-after": { summaries: [entry] } });
	assert.equal(cases[0].after.pumpUs.p99, 5);
	assert.equal(cases[0].before.perRun[0].probes.eligibilityChecks, 80);
	entry.key = "audit/Collector/128/8/State/true";
	assert.match(normalize({ "audit-before": { summaries: [entry] }, "audit-after": { summaries: [entry] } })[0].comparisonScope, /^N10-only/);
});

test("audit v2 preserves recovery censoring, collector availability and ledger units", t => {
	const { directory } = fixture(t);
	const entry = { kind: "Collector", actors: 128, recipients: 8, mode: "Events", diagnostic: true,
		collectorAvailable: false, unservedDuringLoad: 91, peakPendingBytes: 100, raw: { pumpUs: [1], waits: [] } };
	const file = path.join(directory, "audit-run1.json");
	const observation = { success: true, workloadVersion: 2, cases: [entry], environment: {
		implementationRevision: "reference", studioFileVersion: "studio", sourceSHA256: { source: "HASH" },
		harnessSHA256: { "tests/benchmarks/NetworkingAudit.luau": "HASH" } } };
	const analyze = () => spawnSync(process.execPath, [path.join(__dirname, "analyze-networking-baseline.cjs"), directory], { encoding: "utf8" });
	fs.writeFileSync(file, JSON.stringify(observation));
	let result = analyze();
	assert.equal(result.status, 0, result.stderr);
	const baseline = JSON.parse(result.stdout).summaries[0].perRun[0];
	assert.equal(baseline.collectorAvailable, false);
	assert.equal(baseline.peakLedgerBytes, undefined);
	assert.equal(baseline.unservedDuringLoad, 91);
	entry.collectorAvailable = true; entry.peakLedgerBytes = 45;
	fs.writeFileSync(file, JSON.stringify(observation));
	result = analyze();
	assert.equal(result.status, 0, result.stderr);
	assert.equal(JSON.parse(result.stdout).summaries[0].perRun[0].peakLedgerBytes, 45);
	observation.workloadVersion = 999;
	fs.writeFileSync(file, JSON.stringify(observation));
	assert.notEqual(analyze().status, 0);
});

function fixture(t, config = options([])) {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), "krf-comparison-"));
	t.after(() => {
		assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
		assert.match(path.basename(directory), /^krf-comparison-/);
		fs.rmSync(directory, { recursive: true, force: true });
	});
	const manifest = { version: 1, config, referenceRevision: "reference", candidateRevision: "candidate", studioFileVersion: "studio",
		candidateSourceSHA256: { "src/runtime.luau": "CANDIDATE" }, trials: plan(config) };
	for (const trial of manifest.trials) {
		trial.status = "complete"; trial.result = destination(config, trial); trial.originalDirectory = `original/${trial.id}`;
		const file = contained(directory, trial.result); fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, JSON.stringify({ success: true, workloadVersion: 2, environment: {
			implementationRevision: trial.arm === "before" ? "reference" : "candidate", harnessRevision: "candidate", studioFileVersion: "studio",
			sourceSHA256: { "src/runtime.luau": trial.arm === "before" ? "REFERENCE" : "CANDIDATE" },
			harnessSHA256: { fixture: "COMMON" }, workloadSHA256: "COMMON", workloadSourcesSHA256: { fixture: "COMMON" },
			schedulerBudget: { records: trial.arm === "after" ? config.candidateRecords : config.records, bytes: config.bytes },
		} }));
		trial.resultSHA256 = hash(file);
	}
	return { directory, manifest };
}

test("candidate record tuning preserves the reference capacity and verifies each arm", t => {
	const config = options(["--candidate-records", "128"]);
	assert.equal(config.records, 64);
	assert.equal(config.candidateRecords, 128);
	assert.throws(() => options(["--candidate-records", "0"]));
	const { directory, manifest } = fixture(t, config);
	verify(directory, manifest);
	const trial = manifest.trials[0], file = contained(directory, trial.result), result = JSON.parse(fs.readFileSync(file, "utf8"));
	result.environment.schedulerBudget.records = 128;
	fs.writeFileSync(file, JSON.stringify(result)); trial.resultSHA256 = hash(file);
	assert.throws(() => verify(directory, manifest), /Wrong scheduler budget/);
});

test("scheduler focus selects an explicit CPU publication subset and rejects other profiles", () => {
	assert.equal(options(["--workload", "publication", "--focus", "scheduler"]).focus, "scheduler");
	for (const args of [["--focus", "unknown"], ["--focus", "scheduler"], ["--focus", "scheduler", "--workload", "publication", "--profile", "native"]]) assert.throws(() => options(args));
});

test("join-state focus accepts only the exact audit scene and completed join samples", t => {
	const config = options(["--workload", "audit", "--focus", "join-state", "--repetitions", "2"]);
	assert.equal(plan(config).length, 4);
	for (const args of [["--focus", "join-state"], ["--workload", "publication", "--focus", "join-state"]]) assert.throws(() => options(args));
	const { directory, manifest } = fixture(t, config);
	const rewrite = change => {
		for (const trial of manifest.trials) {
			const file = contained(directory, trial.result), result = JSON.parse(fs.readFileSync(file, "utf8"));
			result.benchmarkFocus = result.environment.benchmarkFocus = "join-state";
			result.cases = [{ kind: "Scene", actors: 128, recipients: 32, mode: "State", diagnostic: false,
				initialJoin: { completed: 4096, pumps: 2, rawPumpUs: [1, 2] } }];
			change(result.cases[0]);
			fs.writeFileSync(file, JSON.stringify(result)); trial.resultSHA256 = hash(file);
		}
	};
	rewrite(() => {});
	verify(directory, manifest);
	for (const change of [entry => { entry.actors = 64; }, entry => { entry.initialJoin.completed--; },
		entry => { entry.initialJoin.rawPumpUs.pop(); }, entry => { entry.diagnostic = true; }]) {
		rewrite(change);
		assert.throws(() => verify(directory, manifest), /Incomplete join-state focus/);
	}
});

test("scheduler focus rejects missing or incompatible selected cases", t => {
	const { directory, manifest } = fixture(t, options(["--workload", "publication", "--focus", "scheduler"]));
	for (const trial of manifest.trials) {
		const file = contained(directory, trial.result), result = JSON.parse(fs.readFileSync(file, "utf8"));
		result.benchmarkFocus = result.environment.benchmarkFocus = "scheduler";
		result.cases = ["Ordinary", "Heavy", "Burst"].flatMap(mode => [2, 30].flatMap(recipients => [0, 40].map(syntheticActionsLobbyWide => ({ mode, recipients, syntheticActionsLobbyWide, actors: 90, diagnostic: false }))));
		fs.writeFileSync(file, JSON.stringify(result)); trial.resultSHA256 = hash(file);
	}
	verify(directory, manifest);
	const trial = manifest.trials[1], file = contained(directory, trial.result), result = JSON.parse(fs.readFileSync(file, "utf8"));
	result.cases.pop(); fs.writeFileSync(file, JSON.stringify(result)); trial.resultSHA256 = hash(file);
	assert.throws(() => verify(directory, manifest), /Incomplete scheduler focus/);
});

test("all planned observations must be complete, distinct and unchanged", t => {
	const { directory, manifest } = fixture(t);
	verify(directory, manifest);
	const incomplete = structuredClone(manifest); incomplete.trials.pop();
	assert.throws(() => verify(directory, incomplete), /trial plan/);
	const prefix = structuredClone(manifest); prefix.trials[1].status = "pending";
	verify(directory, prefix, true);
	assert.throws(() => verify(directory, prefix), /Incomplete trial/);
	const failed = structuredClone(manifest); failed.trials[0].status = "failed";
	assert.throws(() => verify(directory, failed), /Incomplete trial/);
	const duplicate = structuredClone(manifest); duplicate.trials[1].originalDirectory = duplicate.trials[0].originalDirectory;
	assert.throws(() => verify(directory, duplicate), /Duplicate/);
	fs.appendFileSync(contained(directory, manifest.trials[0].result), " ");
	assert.throws(() => verify(directory, manifest), /Artifact changed/);
});

for (const [field, value, message] of [["implementationRevision", "wrong", /Wrong implementation/], ["harnessRevision", "wrong", /Wrong harness/],
	["schedulerBudget", { records: 128, bytes: 65536 }, /Wrong scheduler budget/],
	["benchmarkFocus", "scheduler", /Wrong benchmark focus/],
	["studioFileVersion", "wrong", /Mixed Studio/], ["harnessSHA256", { fixture: "WRONG" }, /Mixed harness/],
	["workloadSHA256", "wrong", /Mixed cpu workload/], ["sourceSHA256", { source: "WRONG" }, /Candidate source differs/]]) {
	test(`provenance rejects ${field} mismatches`, t => {
		const { directory, manifest } = fixture(t), trial = manifest.trials[1], file = contained(directory, trial.result);
		const result = JSON.parse(fs.readFileSync(file, "utf8")); result.environment[field] = value;
		fs.writeFileSync(file, JSON.stringify(result)); trial.resultSHA256 = hash(file);
		assert.throws(() => verify(directory, manifest), message);
	});
}

test("artifact paths cannot escape the comparison folder", () => assert.throws(() => contained(os.tmpdir(), "../outside.json"), /escapes/));

test("failed reanalysis replaces a stale PASS report and exits nonzero", t => {
	const { directory, manifest } = fixture(t);
	manifest.trials[0].status = "failed";
	fs.writeFileSync(path.join(directory, "manifest.json"), JSON.stringify(manifest));
	fs.writeFileSync(path.join(directory, "comparison.md"), "PASS");
	const result = spawnSync(process.execPath, [path.join(__dirname, "compare-networking.cjs"), "--analyze", directory], { encoding: "utf8" });
	assert.notEqual(result.status, 0);
	assert.match(fs.readFileSync(path.join(directory, "comparison.md"), "utf8"), /FAILED/);
	assert.equal(JSON.parse(fs.readFileSync(path.join(directory, "comparison.json"))).status, "failed");
});

test("reports increased costs even when execution differs and never presents shedding as a gain", () => {
	const arm = { trials: 1, offered: 10, admitted: 10, executed: 10, costUs: 1, latency: { median: 1, p95: 2 },
		peakPending: 1, peakPendingBytes: 23, perRun: [], latencyUnit: "ms" };
	const rendered = report({ trials: [1, 2], config: { workload: "commands" } }, [{ key: "native/2/Pressure", kind: "commands",
		before: arm, after: { ...arm, executed: 5, costUs: 2 } }]);
	assert.equal(rendered.regressions.length, 1);
	assert.equal(rendered.regressions[0].equalExecutions, false);
	assert.match(rendered.markdown, /shedding is not throughput improvement/);
	assert.match(rendered.markdown, /executed work differs/);
});

test("publication comparison preserves separate CPU/native cases and checks equal commits", () => {
	const value = key => ({ key, runs: 1, commits: 10, n4StepUs: { p95: 100 }, observedMs: { median: 1, p95: 2 }, perRun: [] });
	const outputs = { "publication-native": { summaries: [value("native/90/Heavy/0/8/false/n9"), value("native/90/Heavy/0/8/false/candidate")] } };
	const cases = normalize(outputs);
	assert.equal(cases.length, 1);
	assert.equal(cases[0].before.commits, 10);
	assert.equal(cases[0].after.latencyUnit, "ms");
	outputs["publication-native"].summaries[1].commits = 9;
	assert.throws(() => normalize(outputs), /Unequal publication/);
});
