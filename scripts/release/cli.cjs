"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const REPO_ROOT = path.resolve(__dirname, "..", "..");

class ReleaseError extends Error {}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, { cwd: REPO_ROOT, encoding: "utf8", ...options });
	if (result.error) throw new ReleaseError(`${command} could not start: ${result.error.message}`);
	return { exitCode: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

function runChecked(command, args, options = {}) {
	const result = run(command, args, options);
	if (result.exitCode !== 0) {
		throw new ReleaseError(`${command} ${args.join(" ")} failed (${result.exitCode}):\n${result.stderr || result.stdout}`);
	}
	return result.stdout;
}

function parseOptions(args) {
	const options = {};
	for (let index = 0; index < args.length; index += 1) {
		const key = args[index];
		if (!key.startsWith("--")) throw new ReleaseError(`Unexpected argument '${key}'`);
		const value = args[index + 1];
		if (value === undefined || value.startsWith("--")) throw new ReleaseError(`${key} requires a value`);
		options[key.slice(2)] = value;
		index += 1;
	}
	return options;
}

function setOutput(name, value) {
	if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
	console.log(`${name}=${value}`);
}

function writeSummary(markdown) {
	if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown);
	console.log(markdown);
}

module.exports = { REPO_ROOT, ReleaseError, run, runChecked, parseOptions, setOutput, writeSummary };
