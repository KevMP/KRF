#!/usr/bin/env node
import { ASSETS_COMMAND, runAssets } from "../src/assets/cli.js";
import { runGenerator } from "../src/generate/cli.js";
import { WORKFLOW_COMMANDS, runWorkflow } from "../src/workflow/cli.js";

const argv = process.argv.slice(2);
const io = {
	cwd: process.cwd(),
	interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
	stdout: (text) => process.stdout.write(text),
	stderr: (text) => process.stderr.write(text),
};

process.exitCode = WORKFLOW_COMMANDS.includes(argv[0])
	? await runWorkflow(argv, io)
	: argv[0] === ASSETS_COMMAND
		? await runAssets(argv, io)
		: await runGenerator(argv, io);
