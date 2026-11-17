#!/usr/bin/env node
import { runGenerator } from "../src/generate/cli.js";

process.exitCode = await runGenerator(process.argv.slice(2), {
	cwd: process.cwd(),
	interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
	stdout: (text) => process.stdout.write(text),
	stderr: (text) => process.stderr.write(text),
});
