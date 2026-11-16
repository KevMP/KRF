// The KRF project contract: the options a project was created with and the versions it targets.
// create-krf writes it; every krf-tools command reads it.
import fs from "node:fs";
import path from "node:path";
import { z } from "zod";

import { KrfToolError } from "./errors.js";

export const PROJECT_METADATA_FILE = "krf.project.json";
export const PROJECT_METADATA_VERSION = 1;

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const semver = z.string().regex(SEMVER, "must be MAJOR.MINOR.PATCH");

/** Options that change what create-krf generates. */
export const projectOptionsSchema = z.strictObject({
	mode: z.enum(["full", "hybrid"]),
	tooling: z.enum(["standard", "minimal"]),
	ci: z.boolean(),
	agents: z.boolean(),
});

/** Defaults for every generated-output option; `--yes` and the wizard start from these. */
export const PROJECT_OPTION_DEFAULTS = Object.freeze({
	mode: "full",
	tooling: "standard",
	ci: true,
	agents: true,
});

export const projectMetadataSchema = z.strictObject({
	metadataVersion: z.literal(PROJECT_METADATA_VERSION),
	name: z.string().min(1),
	options: projectOptionsSchema,
	creator: z.strictObject({ name: z.literal("create-krf"), version: semver }),
	template: z.strictObject({ version: semver }),
	runtime: z.strictObject({ package: z.string().regex(/^[a-z0-9-]+\/[a-z0-9-]+$/), version: semver }),
	tooling: z.strictObject({ package: z.literal("krf-tools"), version: semver }),
});

/**
 * Serializes metadata with a stable key order so identical inputs produce identical bytes.
 * @param {z.infer<typeof projectMetadataSchema>} metadata
 */
export function serializeProjectMetadata(metadata) {
	const parsed = projectMetadataSchema.parse(metadata);
	const ordered = {
		metadataVersion: parsed.metadataVersion,
		name: parsed.name,
		options: {
			mode: parsed.options.mode,
			tooling: parsed.options.tooling,
			ci: parsed.options.ci,
			agents: parsed.options.agents,
		},
		creator: { name: parsed.creator.name, version: parsed.creator.version },
		template: { version: parsed.template.version },
		runtime: { package: parsed.runtime.package, version: parsed.runtime.version },
		tooling: { package: parsed.tooling.package, version: parsed.tooling.version },
	};

	return `${JSON.stringify(ordered, null, 2)}\n`;
}

/**
 * Reads and validates the metadata of the project rooted at `projectRoot`.
 * @param {string} projectRoot
 * @returns {z.infer<typeof projectMetadataSchema>}
 */
export function readProjectMetadata(projectRoot) {
	const file = path.join(projectRoot, PROJECT_METADATA_FILE);
	let text;

	try {
		text = fs.readFileSync(file, "utf8");
	} catch (error) {
		if (error?.code === "ENOENT") {
			throw new KrfToolError("ProjectMetadataMissing", `No ${PROJECT_METADATA_FILE} in ${projectRoot}.`, {
				hint: "Run this command from the root of a project created by create-krf.",
			});
		}
		throw error;
	}

	let json;
	try {
		json = JSON.parse(text);
	} catch (error) {
		throw new KrfToolError("ProjectMetadataInvalid", `${PROJECT_METADATA_FILE} is not valid JSON.`, { cause: error });
	}

	const result = projectMetadataSchema.safeParse(json);
	if (!result.success) {
		const issues = result.error.issues.map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`);
		throw new KrfToolError("ProjectMetadataInvalid", `${PROJECT_METADATA_FILE} is invalid:\n  ${issues.join("\n  ")}`);
	}

	return result.data;
}
