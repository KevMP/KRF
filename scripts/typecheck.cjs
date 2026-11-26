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

function analyze(sourcemap, inputs) {
	return runTool("luau-lsp", [
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
	]);
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
