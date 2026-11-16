// Interactive wizard. It only collects answers; normalizeConfig validates them like flags.
import * as clack from "@clack/prompts";
import { ExitCode, KrfToolError, PROJECT_OPTION_DEFAULTS, inspectTarget } from "krf-tools";

import { SETUP_DEFAULTS, resolveProjectPath } from "./options.js";

function cancelled() {
	return new KrfToolError("Cancelled", "Project creation cancelled. No files were written.", { exitCode: ExitCode.cancelled });
}

async function ask(prompts, prompt) {
	const value = await prompt;
	if (prompts.isCancel(value)) throw cancelled();
	return value;
}

/**
 * Asks for every value the command line did not supply.
 * @param {import("./options.js").CreatorInput} given
 * @param {{ cwd: string, prompts?: typeof clack }} context
 * @returns {Promise<import("./options.js").CreatorInput>}
 */
export async function promptForMissing(given, context) {
	const prompts = context.prompts ?? clack;
	const answers = { ...given };

	prompts.intro("create-krf");

	if (answers.projectPath === undefined) {
		answers.projectPath = await ask(
			prompts,
			prompts.text({
				message: "Project name",
				placeholder: "my-game",
				validate(value) {
					try {
						inspectTarget(resolveProjectPath(value ?? "", context.cwd).target);
						return undefined;
					} catch (error) {
						return error instanceof KrfToolError ? error.message : String(error);
					}
				},
			}),
		);
	}

	if (answers.mode === undefined) {
		answers.mode = await ask(
			prompts,
			prompts.select({
				message: "Project mode",
				initialValue: PROJECT_OPTION_DEFAULTS.mode,
				options: [
					{ value: "full", label: "Full", hint: "Git and Rojo own the whole place" },
					{ value: "hybrid", label: "Hybrid", hint: "Rojo owns code; Studio keeps world content" },
				],
			}),
		);
	}

	if (answers.tooling === undefined) {
		answers.tooling = await ask(
			prompts,
			prompts.select({
				message: "Developer tooling",
				initialValue: PROJECT_OPTION_DEFAULTS.tooling,
				options: [
					{ value: "standard", label: "Standard", hint: "formatting, linting, type checks and tests" },
					{ value: "minimal", label: "Minimal", hint: "build only" },
				],
			}),
		);
	}

	const confirmations = [
		["ci", "Add a GitHub Actions workflow?", PROJECT_OPTION_DEFAULTS.ci],
		["agents", "Add instructions for AI coding agents?", PROJECT_OPTION_DEFAULTS.agents],
		["git", "Initialize a Git repository?", SETUP_DEFAULTS.git],
		["install", "Install npm dependencies?", SETUP_DEFAULTS.install],
	];

	for (const [key, message, initialValue] of confirmations) {
		if (answers[key] === undefined) answers[key] = await ask(prompts, prompts.confirm({ message, initialValue }));
	}

	return answers;
}
