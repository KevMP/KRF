const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const { prepareSkillExamples } = require("./skill-examples.cjs");

const TEMP_DIR = ".typecheck";
const DEFINITIONS_PATH = path.join(TEMP_DIR, "globalTypes.PluginSecurity.d.luau");
const DEFINITIONS_URL = "https://luau-lsp.pages.dev/type-definitions/globalTypes.PluginSecurity.d.luau";
const SKILL_EXAMPLES = path.join(TEMP_DIR, "skill-examples");

async function downloadRobloxDefinitions() {
	const response = await fetch(DEFINITIONS_URL);
	if (!response.ok) {
		throw new Error(`Failed to download Roblox definitions: ${response.status} ${response.statusText}`);
	}

	fs.mkdirSync(TEMP_DIR, { recursive: true });
	fs.writeFileSync(DEFINITIONS_PATH, await response.text());
}

function runTool(command, args) {
	const executable = process.platform === "win32" ? `${command}.exe` : command;
	const result = cp.spawnSync(executable, args, { stdio: "inherit" });
	return result.status ?? 1;
}

function analyze(sourcemap, inputs, expectedErrors) {
	const args = [
		"analyze",
		"--flag:LuauSolverV2=true",
		"--platform",
		"roblox",
		"--no-strict-dm-types",
		`--definitions:@roblox=${DEFINITIONS_PATH}`,
		"--sourcemap",
		sourcemap,
		"--formatter",
		"gnu",
		"--ignore",
		"DevPackages/**",
		"--ignore",
		"**/_Index/**",
		...inputs,
	];
	if (!expectedErrors) return runTool("luau-lsp", args);

	const executable = process.platform === "win32" ? "luau-lsp.exe" : "luau-lsp";
	const result = cp.spawnSync(executable, args, { encoding: "utf8" });
	const output = (result.stdout ?? "") + (result.stderr ?? "");
	const diagnostics = output.split(/\r?\n/).filter((line) => /(?:Type|Syntax)Error:/.test(line));
	const actual = new Set();
	let unexpected = result.status !== 1;
	for (const diagnostic of diagnostics) {
		const match = /:(\d+)\.\d+(?:-\d+\.\d+)?: TypeError:/.exec(diagnostic);
		if (!diagnostic.includes(expectedErrors.file) || !match || /too complex|Unknown require|Unknown type/.test(diagnostic)) {
			unexpected = true;
		} else {
			actual.add(Number(match[1]));
		}
	}
	if (unexpected || actual.size !== expectedErrors.lines.size || [...actual].some((line) => !expectedErrors.lines.has(line))) {
		console.error(output);
		console.error(`${expectedErrors.file}: expected errors on lines ${[...expectedErrors.lines]}, got ${[...actual]}`);
		return 1;
	}
	console.log(`${expectedErrors.file}: rejected ${actual.size} invalid calls/payloads with LuauSolverV2`);
	return 0;
}

function analyzePresentationTypes() {
	const directory = path.join(TEMP_DIR, "presentation");
	fs.mkdirSync(directory, { recursive: true });
	const families = ["PresentationOn", "PresentationWatch", "PresentationPrediction"];
	const fixtures = {};
	for (const family of families) {
		for (const kind of ["positive", "negative"]) {
			const name = `${family}.${kind}`;
			fs.copyFileSync(path.join("tests/typecheck", `${name}.luau.txt`), path.join(directory, `${name}.luau`));
			fixtures[name] = { $path: `${name}.luau` };
		}
	}
	const project = path.join(directory, "presentation.project.json");
	const sourcemap = path.join(directory, "sourcemap.json");
	fs.writeFileSync(project, JSON.stringify({ name: "PresentationTypes", tree: {
		$className: "DataModel", ReplicatedStorage: {
			$className: "ReplicatedStorage", Packages: { $className: "Folder", KRF: { $path: path.resolve("src") } },
			...fixtures,
		},
	} }));
	fs.writeFileSync(path.join(directory, ".luaurc"), JSON.stringify({ languageMode: "strict", lint: { "*": false } }));
	let status = runTool("rojo", ["sourcemap", "--absolute", project, "--output", sourcemap]);
	if (status !== 0) return status;
	for (const family of families) {
		status = analyze(sourcemap, [path.join(directory, `${family}.positive.luau`)]);
		if (status !== 0) return status;
		const file = `${family}.negative.luau`;
		const lines = new Set(fs.readFileSync(path.join(directory, file), "utf8").split(/\r?\n/)
			.flatMap((line, index) => line.includes("-- expect-error") ? [index + 1] : []));
		status = analyze(sourcemap, [path.join(directory, file)], { file, lines });
		if (status !== 0) return status;
	}
	return 0;
}

function analyzeSkillExamples() {
	const examples = prepareSkillExamples(SKILL_EXAMPLES);
	const exitCode = runTool("rojo", ["sourcemap", "--absolute", examples.project, "--output", examples.sourcemap]);
	return exitCode === 0 ? analyze(examples.sourcemap, [SKILL_EXAMPLES]) : exitCode;
}

async function main() {
	let exitCode = 1;

	try {
		await downloadRobloxDefinitions();

		exitCode = runTool("rojo", [
			"sourcemap",
			"--include-non-scripts",
			"test.project.json",
			"--output",
			"sourcemap.json",
		]);

		if (exitCode === 0) {
			exitCode = analyzePresentationTypes();
		}

		if (exitCode === 0) {
			exitCode = analyze("sourcemap.json", ["src", "tests"]);
		}

		if (exitCode === 0) {
			exitCode = analyzeSkillExamples();
		}
	} finally {
		fs.rmSync(TEMP_DIR, { recursive: true, force: true });
	}

	process.exit(exitCode);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
