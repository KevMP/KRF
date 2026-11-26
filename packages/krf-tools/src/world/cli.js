import { Command, CommanderError } from "commander";

import { TOOLS_COMMAND, TOOLS_VERSION } from "../compatibility.js";
import { ExitCode, KrfToolError, formatError } from "../errors.js";
import { projectForPlace, readLocalProject } from "../workflow/project.js";
import { SYSTEM } from "../workflow/tools.js";
import { runSyncback } from "./syncback.js";

export const WORLD_COMMAND = "world";

export const WORLD_SCRIPTS = Object.freeze({
	"world:syncback": `krf-tools ${WORLD_COMMAND} syncback`,
});

function buildProgram(io, onSelect) {
	const program = new Command(TOOLS_COMMAND)
		.version(TOOLS_VERSION, "-v, --version")
		.exitOverride()
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr });

	const world = program.command(WORLD_COMMAND).description("Sync Studio-authored world content back into source");

	world
		.command("syncback")
		.description("Sync the project-mapped world trees of a saved Studio place back into source files with rojo syncback")
		.option("--place <name>", "the named Full place to capture (default: the start place)")
		.option("--input <file>", "the .rbxl or .rbxlx file saved from Roblox Studio (default: the local Studio file for the selected place)")
		.option("--dry-run", "report the files a capture would write or remove, without writing")
		.option("--allow-dirty", "capture even when the captured folders have uncommitted Git changes; the current files are copied to build/krf first")
		.action((options) => onSelect("syncback", options));

	return program;
}

export async function runWorld(argv, io, system = SYSTEM) {
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
		const options = { input: selected.options.input, dryRun: selected.options.dryRun === true, allowDirty: selected.options.allowDirty === true };
		const project = readLocalProject(io.cwd);
		return await runSyncback(system, selected.options.place === undefined ? project : projectForPlace(project, selected.options.place), options, io);
	} catch (error) {
		if (error instanceof CommanderError) {
			return error.code === "commander.helpDisplayed" || error.code === "commander.version" ? ExitCode.ok : ExitCode.usage;
		}
		io.stderr(`${formatError(error)}\n`);
		return error instanceof KrfToolError ? error.exitCode : ExitCode.failure;
	}
}
