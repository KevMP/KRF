import { Command, CommanderError } from "commander";
import { z } from "zod";

import { TOOLS_PACKAGE, TOOLS_VERSION } from "../compatibility.js";
import { ExitCode, KrfToolError, formatError } from "../errors.js";
import { runDev } from "./dev.js";
import { readLocalProject } from "./project.js";
import { runStudioSmoke, runTests } from "./tests.js";
import { SYSTEM } from "./tools.js";

export const WORKFLOW_COMMANDS = Object.freeze(["dev", "test", "test-studio"]);

const integer = (minimum, maximum) => z.coerce.number().int().min(minimum).max(maximum);
const STUDIO_PATH = ["--studio-path <path>", "the Roblox Studio executable, when it is not found automatically"];
const TIMEOUT = ["--timeout <seconds>", "how long Roblox Studio may run before the run fails", "300"];

const OPTION_SCHEMAS = {
	dev: z.object({
		open: z.boolean(),
		capture: z.boolean(),
		studioPath: z.string().optional(),
		port: integer(1, 65535).optional(),
		place: z.string().optional(),
	}),
	test: z.object({ studioPath: z.string().optional(), timeout: integer(1, 3600) }),
	"test-studio": z.object({ studioPath: z.string().optional(), timeout: integer(1, 3600), clients: integer(1, 8) }),
};

const RUNNERS = {
	dev: runDev,
	test: runTests,
	"test-studio": (system, project, options, io) => runStudioSmoke(system, project, { ...options, smokeTimeout: Math.max(1, Math.min(60, options.timeout - 30)) }, io),
};

function buildProgram(io, onSelect) {
	const program = new Command(TOOLS_PACKAGE)
		.version(TOOLS_VERSION, "-v, --version")
		.exitOverride()
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr });

	program
		.command("dev")
		.description("Build the place, serve it with Rojo and open it in Roblox Studio")
		.option("--no-open", "serve without opening Roblox Studio")
		.option("--no-capture", "do not capture the world into source files when Studio saves the place")
		.option(...STUDIO_PATH)
		.option("--port <port>", "the rojo serve port (default: 34872)")
		.option("--place <file>", "Hybrid projects: the Studio place that holds your world (default: <name>.rbxl)")
		.action((options) => onSelect("dev", options));

	program
		.command("test")
		.description("Run the Jest specs in tests/ inside Roblox Studio")
		.option(...STUDIO_PATH)
		.option(...TIMEOUT)
		.action((options) => onSelect("test", options));

	program
		.command("test-studio")
		.description("Play the game in Roblox Studio with a server and clients, and check that KRF starts and every player character becomes an Actor")
		.option(...STUDIO_PATH)
		.option(...TIMEOUT)
		.option("--clients <count>", "how many clients join", "2")
		.action((options) => onSelect("test-studio", options));

	return program;
}

export async function runWorkflow(argv, io, system = SYSTEM) {
	let selected;
	const program = buildProgram(io, (command, options) => {
		selected = { command, options };
	});

	try {
		program.parse(argv, { from: "user" });
		const parsed = OPTION_SCHEMAS[selected.command].safeParse(selected.options);
		if (!parsed.success) {
			const issue = parsed.error.issues[0];
			throw new KrfToolError("InvalidOption", `Invalid --${String(issue.path[0]).replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}: ${issue.message}.`, { exitCode: ExitCode.usage });
		}
		const project = readLocalProject(io.cwd);
		return await RUNNERS[selected.command](system, project, parsed.data, io);
	} catch (error) {
		if (error instanceof CommanderError) {
			return error.code === "commander.helpDisplayed" || error.code === "commander.version" ? ExitCode.ok : ExitCode.usage;
		}
		io.stderr(`${formatError(error)}\n`);
		return error instanceof KrfToolError ? error.exitCode : ExitCode.failure;
	}
}
