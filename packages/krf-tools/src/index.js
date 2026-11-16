// Public API shared with create-krf. Game projects use krf-tools through npm scripts.
export { ExitCode, KrfToolError, formatError } from "./errors.js";
export {
	PROJECT_METADATA_FILE,
	PROJECT_METADATA_VERSION,
	PROJECT_OPTION_DEFAULTS,
	projectMetadataSchema,
	projectOptionsSchema,
	readProjectMetadata,
	serializeProjectMetadata,
} from "./project.js";
export { outputPath, renderTemplates } from "./render.js";
export { inspectTarget, writeNewDirectory } from "./files.js";
export { TOOLING_VERSION, runCli } from "./cli.js";
