import * as clack from "@clack/prompts";
import { ExitCode, KrfToolError, PROJECT_OPTION_DEFAULTS, inspectTarget } from "krf-tools";

import { resolveProjectPath } from "./options.js";

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
					{ value: "full", label: "Full", hint: "code and world live in this repo; npm run build makes the whole place" },
					{ value: "hybrid", label: "Hybrid", hint: "only code lives in this repo; you build the world in Studio and keep the place file" },
				],
			}),
		);
	}

	if (answers.ci === undefined) {
		answers.ci = await ask(
			prompts,
			prompts.confirm({
				message: "Add a GitHub Actions workflow that checks and builds on every push and pull request?",
				initialValue: PROJECT_OPTION_DEFAULTS.ci,
			}),
		);
	}

	return answers;
}
