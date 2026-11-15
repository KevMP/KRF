// Internal executable behind a KRF project's npm scripts. Game developers run `npm run <script>`;
// they never need to call krf-tools directly.
import { Command, CommanderError } from "commander";

import packageJson from "../package.json" with { type: "json" };
import { ExitCode, KrfToolError, formatError } from "./errors.js";
import { PROJECT_METADATA_FILE, readProjectMetadata } from "./project.js";

export const TOOLING_VERSION = packageJson.version;

/**
 * @typedef {{ cwd: string, stdout: (text: string) => void, stderr: (text: string) => void }} CliIo
 */

function info(io, options) {
	const metadata = readProjectMetadata(io.cwd);

	if (metadata.tooling.version !== TOOLING_VERSION) {
		throw new KrfToolError(
			"ToolingVersionMismatch",
			`${PROJECT_METADATA_FILE} pins krf-tools ${metadata.tooling.version}, but ${TOOLING_VERSION} is installed.`,
			{ hint: "Run npm install so the project uses the krf-tools version it declares." },
		);
	}

	if (options.json) {
		io.stdout(`${JSON.stringify({ ok: true, project: metadata }, null, 2)}\n`);
		return;
	}

	io.stdout(
		[
			`${metadata.name}`,
			`  Mode:      ${metadata.options.mode}`,
			`  Tooling:   ${metadata.options.tooling}`,
			`  CI:        ${metadata.options.ci ? "yes" : "no"}`,
			`  Agents:    ${metadata.options.agents ? "yes" : "no"}`,
			`  KRF:       ${metadata.runtime.package}@${metadata.runtime.version}`,
			`  Tools:     krf-tools@${metadata.tooling.version}`,
			`  Template:  create-krf ${metadata.template.version}`,
			"",
		].join("\n"),
	);
}

/**
 * Runs one krf-tools command and returns its exit code.
 * @param {string[]} argv Arguments after the executable name.
 * @param {CliIo} io
 */
export async function runCli(argv, io) {
	const program = new Command("krf-tools")
		.description("Project tooling for KRF games. Use the npm scripts in package.json.")
		.version(TOOLING_VERSION, "-v, --version")
		.exitOverride()
		.showSuggestionAfterError(false)
		.configureOutput({ writeOut: io.stdout, writeErr: io.stderr });

	program
		.command("info")
		.description(`Validate ${PROJECT_METADATA_FILE} and show the project's options and versions`)
		.option("--json", "print machine-readable output")
		.action((options) => info(io, options));

	program.on("command:*", ([name]) => {
		const available = program.commands.map((command) => command.name()).join(", ");
		throw new KrfToolError("UnknownCommand", `krf-tools ${TOOLING_VERSION} has no '${name}' command.`, {
			hint: `Available commands: ${available}. A newer krf-tools may add it; check the project's npm scripts.`,
			exitCode: ExitCode.usage,
		});
	});

	try {
		await program.parseAsync(argv, { from: "user" });
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
