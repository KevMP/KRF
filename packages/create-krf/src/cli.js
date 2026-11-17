// `npm create krf@latest [project-name] -- [options]`: the wizard and flags share one config.
import path from "node:path";
import { Command, CommanderError, Option } from "commander";
import { ExitCode, KRF_RUNTIME, KrfToolError, formatError } from "krf-tools";

import { CREATOR_VERSION } from "./compatibility.js";
import { assertSetupSucceeded, createProject } from "./create.js";
import { normalizeConfig } from "./options.js";
import { promptForMissing } from "./prompts.js";

/**
 * @typedef {{
 *   cwd: string,
 *   interactive: boolean,
 *   stdout: (text: string) => void,
 *   stderr: (text: string) => void,
 *   prompts?: typeof import("@clack/prompts"),
 *   run?: import("./create.js").ProcessRunner,
 * }} CreatorIo
 */

function buildProgram(io) {
	return new Command("create-krf")
		.description(`Create a KRF Roblox game project (KRF ${KRF_RUNTIME.package}@${KRF_RUNTIME.version}).`)
		.argument("[project-name]", "directory to create; its name becomes the project name")
		.addOption(new Option("--mode <mode>", "Rojo ownership: full or hybrid (default: full)"))
		.option("--ci", "add a GitHub Actions workflow that checks and builds (default)")
		.option("--no-ci", "do not add a GitHub Actions workflow")
		.option("--no-git", "do not initialize a Git repository")
		.option("-y, --yes", "use defaults for every value not given; never prompt")
		.version(CREATOR_VERSION, "-v, --version")
		.helpOption("-h, --help")
		.exitOverride()
		.showSuggestionAfterError(true)
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr })
		.addHelpText(
			"after",
			"\nExamples:\n  npm create krf@latest\n  npm create krf@latest my-game -- --yes\n  npx create-krf@latest my-game --mode hybrid --no-ci\n",
		);
}

function inputFromFlags(projectPath, flags, program) {
	const given = (name) => program.getOptionValueSource(name) === "cli";

	return {
		projectPath,
		mode: flags.mode,
		ci: given("ci") ? flags.ci : undefined,
		git: given("git") ? flags.git : undefined,
	};
}

function report(io, config, result) {
	const lines = [`Created ${config.name} in ${config.target}`, `  ${result.files.length} files`];
	for (const step of result.steps) lines.push(`  ${step.name}: ${step.status}${step.detail ? ` (${step.detail})` : ""}`);

	lines.push("", "Next:", `  cd ${path.relative(io.cwd, config.target) || "."}`, "  npm install", "  npm run dev", "");

	io.stdout(`${lines.join("\n")}\n`);
}

/**
 * Runs create-krf and returns its exit code.
 * @param {string[]} argv Arguments after the executable name.
 * @param {CreatorIo} io
 */
export async function runCreator(argv, io) {
	const program = buildProgram(io);

	try {
		program.parse(argv, { from: "user" });
		const flags = program.opts();
		let input = inputFromFlags(program.args[0], flags, program);

		if (!flags.yes) {
			if (io.interactive) {
				input = await promptForMissing(input, { cwd: io.cwd, prompts: io.prompts });
			} else if (input.projectPath === undefined) {
				throw new KrfToolError("ProjectNameMissing", "A project name is required when not running interactively.", {
					hint: "Pass the name and --yes, for example: npx create-krf@latest my-game --yes",
					exitCode: ExitCode.usage,
				});
			}
		}

		const config = normalizeConfig(input, io.cwd);
		const result = createProject(config, { run: io.run });
		report(io, config, result);
		assertSetupSucceeded(result, config.target);

		return ExitCode.ok;
	} catch (error) {
		if (error instanceof CommanderError) {
			if (error.code === "commander.helpDisplayed" || error.code === "commander.version" || error.code === "commander.help") {
				return ExitCode.ok;
			}
			return ExitCode.usage;
		}

		io.stderr(`${formatError(error)}\n`);
		return error instanceof KrfToolError ? error.exitCode : ExitCode.failure;
	}
}
