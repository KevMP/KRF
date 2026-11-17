// One normalized configuration for the wizard, `--yes` and explicit flags.
import path from "node:path";
import { z } from "zod";
import { ExitCode, KrfToolError, PROJECT_OPTION_DEFAULTS, projectOptionsSchema } from "krf-tools";

/** Defaults for steps that run after the files are written. */
export const SETUP_DEFAULTS = Object.freeze({ git: true });

const RESERVED_NAMES = new Set(["node_modules", "favicon.ico", "krf", "create-krf", "krf-tools"]);

/**
 * Returns why a project name is unusable, or undefined. Names become the npm package name and
 * the directory name, so they follow npm's lowercase, URL-safe rules.
 * @param {string} name
 */
export function projectNameProblem(name) {
	if (typeof name !== "string" || name.length === 0) return "Enter a project name.";
	if (name.length > 214) return "Project names must be 214 characters or fewer.";
	if (!/^[a-z0-9][a-z0-9._-]*$/.test(name)) {
		return "Use lowercase letters, digits, '-', '_' or '.', starting with a letter or digit.";
	}
	if (RESERVED_NAMES.has(name)) return `'${name}' is reserved; choose another name.`;
	return undefined;
}

/**
 * Resolves the requested project path. The last segment is the project name; `..` segments and
 * filesystem roots are refused so generated files stay where the caller pointed.
 * @param {string} projectPath
 * @param {string} cwd
 */
export function resolveProjectPath(projectPath, cwd) {
	if (typeof projectPath !== "string" || projectPath.trim() === "") {
		throw new KrfToolError("ProjectNameMissing", "A project name is required.", {
			hint: "Pass it as the first argument, for example: npm create krf@latest my-game -- --yes",
			exitCode: ExitCode.usage,
		});
	}

	if (projectPath.split(/[\\/]+/).includes("..")) {
		throw new KrfToolError("UnsafeProjectPath", `'${projectPath}' contains a '..' segment.`, {
			hint: "Run create-krf from the parent directory and pass the new project's name.",
			exitCode: ExitCode.usage,
		});
	}

	const target = path.resolve(cwd, projectPath);
	if (path.dirname(target) === target) {
		throw new KrfToolError("UnsafeProjectPath", "A filesystem root cannot be a project directory.", { exitCode: ExitCode.usage });
	}

	const name = path.basename(target);
	const problem = projectNameProblem(name);
	if (problem) {
		throw new KrfToolError("InvalidProjectName", `Invalid project name '${name}'. ${problem}`, { exitCode: ExitCode.usage });
	}

	return { target, name };
}

export const creatorConfigSchema = z.strictObject({
	target: z.string().min(1),
	name: z.string().min(1),
	options: projectOptionsSchema,
	git: z.boolean(),
});

/**
 * @typedef {{ projectPath?: string, mode?: string, ci?: boolean, git?: boolean }} CreatorInput
 * @typedef {z.infer<typeof creatorConfigSchema>} CreatorConfig
 */

/**
 * Applies defaults to whatever the flags or wizard supplied and validates the result.
 * @param {CreatorInput} input
 * @param {string} cwd
 * @returns {CreatorConfig}
 */
export function normalizeConfig(input, cwd) {
	const { target, name } = resolveProjectPath(input.projectPath, cwd);
	const candidate = {
		target,
		name,
		options: {
			mode: input.mode ?? PROJECT_OPTION_DEFAULTS.mode,
			ci: input.ci ?? PROJECT_OPTION_DEFAULTS.ci,
		},
		git: input.git ?? SETUP_DEFAULTS.git,
	};

	const result = creatorConfigSchema.safeParse(candidate);
	if (!result.success) {
		const issue = result.error.issues[0];
		const field = issue.path.at(-1);
		throw new KrfToolError("InvalidOption", `Invalid --${String(field)}: ${issue.message}.`, {
			hint: "Run create-krf --help for supported values.",
			exitCode: ExitCode.usage,
		});
	}

	return result.data;
}
