import { ExitCode, KrfToolError } from "../errors.js";
import { CATALOGS } from "./catalogs.js";

const STATUS_EXIT_CODES = Object.freeze({
	created: ExitCode.ok,
	"dry-run": ExitCode.ok,
	"already-exists": ExitCode.alreadyExists,
	"created-not-loaded": ExitCode.createdNotLoaded,
	"manual-wiring-required": ExitCode.manualWiringRequired,
});

export function resultOf(plan, dryRun) {
	return {
		status: dryRun && plan.status !== "already-exists" ? "dry-run" : plan.status,
		...(dryRun && plan.status !== "already-exists" ? { outcome: plan.status } : {}),
		kind: plan.kind,
		name: plan.name,
		id: plan.id,
		file: plan.file,
		changes: plan.changes.map((change) => ({ path: change.path, change: change.kind })),
		manual: plan.manual,
		next: plan.next,
		warnings: plan.warnings,
	};
}

export function errorResult(error) {
	return {
		status: "error",
		error: {
			code: error instanceof KrfToolError ? error.code : "UnexpectedError",
			message: error instanceof Error ? error.message : String(error),
			...(error instanceof KrfToolError && error.hint ? { hint: error.hint } : {}),
		},
	};
}

const HEADLINES = {
	created: (result) => `Created ${result.file}. It loads on the next build.`,
	"created-not-loaded": (result) => `Created ${result.file}, but nothing loads it.`,
	"manual-wiring-required": (result) => `Created ${result.file}. Finish wiring it by hand:`,
	"already-exists": (result) => `${result.file} already exists. Nothing was written.`,
};

export function formatResult(result) {
	const label = CATALOGS[result.kind].label;
	const lines = [];

	if (result.status === "dry-run") {
		lines.push(`Dry run: would create the ${label} ${result.id} (${result.outcome}). Nothing was written.`);
		for (const change of result.changes) lines.push(`  would ${change.change} ${change.path}`);
	} else {
		lines.push(HEADLINES[result.status](result));
		for (const change of result.changes.filter((entry) => entry.change === "edit" || entry.path !== result.file)) {
			lines.push(`  ${change.change === "edit" ? "edited" : "created"} ${change.path}`);
		}
	}

	for (const step of result.manual) {
		lines.push("", `${step.file}: ${step.instruction}`, ...step.lines.map((line) => `    ${line}`));
	}

	if (result.next.length > 0) lines.push("", "Next:", ...result.next.map((step) => `  ${step}`));
	return `${lines.join("\n")}\n`;
}

export function exitCodeOf(result) {
	return STATUS_EXIT_CODES[result.status];
}
