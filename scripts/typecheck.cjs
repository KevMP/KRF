const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const TEMP_DIR = ".typecheck";
const DEFINITIONS_PATH = path.join(TEMP_DIR, "globalTypes.PluginSecurity.d.luau");
const DEFINITIONS_URL = "https://luau-lsp.pages.dev/type-definitions/globalTypes.PluginSecurity.d.luau";

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
			exitCode = runTool("luau-lsp", [
				"analyze",
				"--platform",
				"roblox",
				"--no-strict-dm-types",
				`--definitions:@roblox=${DEFINITIONS_PATH}`,
				"--sourcemap",
				"sourcemap.json",
				"--formatter",
				"gnu",
				"--ignore",
				"DevPackages/**",
				"--ignore",
				"**/_Index/**",
				"src",
				"tests",
			]);
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
