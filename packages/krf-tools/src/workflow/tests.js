import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { TEST_PACKAGES } from "../compatibility.js";
import { ExitCode, KrfToolError } from "../errors.js";
import { createConsumer, readKrfDependency } from "../generate/consumer.js";
import { TESTS_FOLDER, deriveProject, runDirectory, service } from "./project.js";
import { acquireStudioLock, between, readMarker, resolveStudio, runStudioScript } from "./studio.js";
import { buildPlace } from "./tools.js";

const STUDIO_SCRIPTS = fileURLToPath(new URL("../../templates/studio/", import.meta.url));

function infrastructureFailure(message, logs) {
	return new KrfToolError("TestInfrastructureFailed", message, { hint: `Studio output: ${logs}`, exitCode: ExitCode.testInfrastructure });
}

function specFiles(directory) {
	if (!fs.existsSync(directory)) return [];
	return fs
		.readdirSync(directory, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && /\.spec\.luau?$/.test(entry.name))
		.map((entry) => path.join(entry.parentPath, entry.name));
}

function assertTestsConfigured(project) {
	const tests = path.join(project.root, TESTS_FOLDER);
	if (specFiles(tests).length === 0) {
		throw new KrfToolError("TestsNotConfigured", `No tests are configured: ${TESTS_FOLDER}/ has no *.spec.luau files.`, {
			hint: `Add a Jest spec such as ${TESTS_FOLDER}/Example.spec.luau.`,
			exitCode: ExitCode.testsNotConfigured,
		});
	}
	if (!["jest.config.luau", "jest.config.lua"].some((file) => fs.existsSync(path.join(tests, file)))) {
		throw new KrfToolError("TestsNotConfigured", `${TESTS_FOLDER}/jest.config.luau is missing.`, {
			hint: 'Create it with: return { testMatch = { "**/*.spec" } }',
			exitCode: ExitCode.testsNotConfigured,
		});
	}
	if (!fs.existsSync(path.join(project.root, "DevPackages", "Jest.lua"))) {
		throw new KrfToolError("JestMissing", "Jest is not installed in DevPackages.", {
			hint: `Add ${Object.entries(TEST_PACKAGES)
				.map(([alias, dependency]) => `${alias} = "${dependency}"`)
				.join(" and ")} under [dev-dependencies] in wally.toml, then run npm install.`,
		});
	}
}

async function inStudio(system, project, options, kind, prepare) {
	const studio = resolveStudio(system, options.studioPath);
	const directory = runDirectory(project, kind);
	const place = path.join(directory, "test.rbxl");
	const source = kind === "test" ? project.codeProject : project.placeProject;
	const projectFile = deriveProject(project, directory, (tree) => prepare(tree, directory), source);
	buildPlace(system, project, projectFile, place);

	const release = acquireStudioLock(project.root);
	try {
		const output = path.join(directory, "output.log");
		const script = path.join(STUDIO_SCRIPTS, kind === "test" ? "RunTests.luau" : "MultiplayerLauncher.luau");
		const run = await runStudioScript(system, { studio, place, script, output, timeoutSeconds: options.timeout });
		if (run.error) throw infrastructureFailure(`Could not start Roblox Studio: ${run.error.message}`, output);
		if (run.timedOut) throw infrastructureFailure(`Roblox Studio did not finish within ${options.timeout} seconds.`, output);
		return { text: run.text, output };
	} finally {
		release();
	}
}

export async function runTests(system, project, options, io) {
	assertTestsConfigured(project);
	const { text, output } = await inStudio(system, project, options, "test", (tree, directory) => {
		const relative = (folder) => path.relative(directory, path.join(project.root, folder)).split(path.sep).join("/");
		const replicated = service(tree, "ReplicatedStorage");
		replicated.DevPackages = { $path: relative("DevPackages") };
		replicated.KRFTests = { $path: relative(TESTS_FOLDER) };
	});

	for (const line of between(text, "__KRF_TEST_OUTPUT_BEGIN__", "__KRF_TEST_OUTPUT_END__")) io.stdout(`${line}\n`);

	const result = readMarker(text, "TEST_RESULT");
	if (result === undefined) throw infrastructureFailure("Roblox Studio finished without reporting a test result.", output);
	if (result.error !== undefined) throw infrastructureFailure(`Jest could not run: ${result.error}`, output);
	if (!(result.numTotalTests > 0)) throw infrastructureFailure("Jest found no tests to run.", output);

	const failed = result.numFailedTests + result.numFailedTestSuites + (result.numRuntimeErrorTestSuites ?? 0);
	if (failed > 0) {
		throw new KrfToolError("TestsFailed", `${result.numFailedTests} of ${result.numTotalTests} tests failed.`, { hint: `Studio output: ${output}` });
	}
	io.stdout(`${result.numPassedTests} of ${result.numTotalTests} tests passed in ${result.numTotalTestSuites} suites.\n`);
	return ExitCode.ok;
}

export async function runStudioSmoke(system, project, options, io) {
	const { alias } = readKrfDependency(createConsumer(project.root));
	const { text, output } = await inStudio(system, project, options, "test-studio", (tree, directory) => {
		for (const file of ["SmokeServer.server.luau", "SmokeClient.client.luau"]) fs.copyFileSync(path.join(STUDIO_SCRIPTS, file), path.join(directory, file));
		const replicated = service(tree, "ReplicatedStorage");
		replicated.KRFStudioTest = { $className: "RemoteEvent", $attributes: { Clients: options.clients, Timeout: options.smokeTimeout, Alias: alias } };
		service(tree, "ServerScriptService").KRFStudioTest = { $path: "SmokeServer.server.luau" };
		const player = service(tree, "StarterPlayer");
		player.StarterPlayerScripts ??= { $className: "StarterPlayerScripts" };
		player.StarterPlayerScripts.KRFStudioTest = { $path: "SmokeClient.client.luau" };
	});

	const result = readMarker(text, "STUDIO_RESULT");
	if (result === undefined) throw infrastructureFailure("Roblox Studio finished without reporting a multiplayer result.", output);
	const summary = `phase ${result.phase ?? "unknown"}, completed ${(result.completed ?? []).join(", ") || "nothing"}`;
	if (result.success !== true) {
		const serverError = typeof result.serverError === "string" ? `\nFirst server error: ${result.serverError}` : "";
		throw new KrfToolError("StudioTestFailed", `The Studio smoke test failed: ${result.reason ?? "no reason given"} (${summary}).${serverError}`, { hint: `Studio output: ${output}` });
	}
	io.stdout(`The server and ${options.clients} clients started KRF, and every player character became an Actor with an ActorView (${summary}).\n`);
	return ExitCode.ok;
}
