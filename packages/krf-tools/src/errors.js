// Structured failures shared by krf-tools commands and create-krf.

/** Process exit codes used by KRF npm tooling. */
export const ExitCode = Object.freeze({
	ok: 0,
	failure: 1,
	usage: 2,
	alreadyExists: 3,
	createdNotLoaded: 4,
	manualWiringRequired: 5,
	testsNotConfigured: 6,
	testInfrastructure: 7,
	cancelled: 130,
});

/**
 * An expected, user-actionable failure. `code` is stable for agents and tests;
 * `hint` tells the user what to do next.
 */
export class KrfToolError extends Error {
	/**
	 * @param {string} code
	 * @param {string} message
	 * @param {{ hint?: string, exitCode?: number, cause?: unknown }} [options]
	 */
	constructor(code, message, options = {}) {
		super(message, { cause: options.cause });
		this.name = "KrfToolError";
		this.code = code;
		this.hint = options.hint;
		this.exitCode = options.exitCode ?? ExitCode.failure;
	}
}

/**
 * Formats an error for a terminal. Unexpected errors keep their stack for diagnosis.
 * @param {unknown} error
 */
export function formatError(error) {
	if (error instanceof KrfToolError) {
		return error.hint ? `${error.message}\n${error.hint}` : error.message;
	}

	return error instanceof Error ? (error.stack ?? error.message) : String(error);
}
