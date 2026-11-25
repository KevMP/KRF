#!/usr/bin/env node
import { WORLD_COMMAND, runWorld } from "../src/world/cli.js";
import { DEPLOY_COMMANDS, runDeployment } from "../src/deploy/cli.js";
import { runGenerator } from "../src/generate/cli.js";
import { WORKFLOW_COMMANDS, runWorkflow } from "../src/workflow/cli.js";

const argv = process.argv.slice(2);
const io = {
	cwd: process.cwd(),
	interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
	stdout: (text) => process.stdout.write(text),
	stderr: (text) => process.stderr.write(text),
};

process.exitCode = DEPLOY_COMMANDS.includes(argv[0])
	? await runDeployment(argv, io)
	: WORKFLOW_COMMANDS.includes(argv[0])
	? await runWorkflow(argv, io)
	: argv[0] === WORLD_COMMAND
		? await runWorld(argv, io)
		: await runGenerator(argv, io);
