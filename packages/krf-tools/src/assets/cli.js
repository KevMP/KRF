import { Command, CommanderError } from "commander";

import { TOOLS_PACKAGE, TOOLS_VERSION } from "../compatibility.js";
import { ExitCode, KrfToolError, formatError } from "../errors.js";
import { readLocalProject } from "../workflow/project.js";
import { SYSTEM } from "../workflow/tools.js";
import { runAssetCheck } from "./check.js";
import { runSyncback } from "./syncback.js";

export const ASSETS_COMMAND = "assets";

export const ASSET_SCRIPTS = Object.freeze({
	"assets:syncback": `krf-tools ${ASSETS_COMMAND} syncback`,
	"assets:check": `krf-tools ${ASSETS_COMMAND} check`,
});

function buildProgram(io, onSelect) {
	const program = new Command(TOOLS_PACKAGE)
		.version(TOOLS_VERSION, "-v, --version")
		.exitOverride()
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr });

	const assets = program.command(ASSETS_COMMAND).description("Capture Studio-authored world content and check hosted asset references");

	assets
		.command("syncback")
		.description("Capture the project-mapped world trees of a saved Studio place into source files with rojo syncback")
		.option("--input <place>", "the .rbxl or .rbxlx file saved from Roblox Studio (default: <name>.rbxl)")
		.option("--dry-run", "report the files a capture would write or remove, without writing")
		.option("--allow-dirty", "capture even when the captured folders have uncommitted Git changes; the current files are copied to build/krf first")
		.action((options) => onSelect("syncback", options));

	assets
		.command("check")
		.description("Validate assets/manifest.json, its source files and hashes, and the generated src/shared/GameAssets.luau")
		.option("--write", "record missing source hashes and regenerate src/shared/GameAssets.luau")
		.action((options) => onSelect("check", options));

	return program;
}

export async function runAssets(argv, io, system = SYSTEM) {
	let selected;
	const program = buildProgram(io, (command, options) => {
		selected = { command, options };
	});

	try {
		program.parse(argv, { from: "user" });
		if (selected === undefined) {
			program.commands[0].outputHelp();
			return ExitCode.usage;
		}
		if (selected.command === "check") return await runAssetCheck(io.cwd, { write: selected.options.write === true }, io);
		const options = { input: selected.options.input, dryRun: selected.options.dryRun === true, allowDirty: selected.options.allowDirty === true };
		return await runSyncback(system, readLocalProject(io.cwd), options, io);
	} catch (error) {
		if (error instanceof CommanderError) {
			return error.code === "commander.helpDisplayed" || error.code === "commander.version" ? ExitCode.ok : ExitCode.usage;
		}
		io.stderr(`${formatError(error)}\n`);
		return error instanceof KrfToolError ? error.exitCode : ExitCode.failure;
	}
}
