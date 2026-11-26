import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { buildProjectFiles } from "../../src/create.js";
import { creatorConfigSchema } from "../../src/options.js";
import { createProject, installPackedCreator, packTarballs, readTree, run, tarballsIn } from "../integration/Utils/packedCreator.js";

const PROJECT_IDENTITY = new Set(["target", "name", "options"]);

const SAMPLE_VALUES = {
	places: [["lobby", "dungeon"]],
};

const FLAGS = {
	mode: (mode) => ["--mode", mode],
	places: (places) => (places === undefined ? [] : ["--places", places.join(",")]),
	ci: (ci) => [ci ? "--ci" : "--no-ci"],
	agents: (agents) => [agents ? "--agents" : "--no-agents"],
	git: (git) => (git ? [] : ["--no-git"]),
};

const SKILL_DOCS = /^\.(agents|claude)\/skills\/krf\/references\/docs\//;
const PLACE_FILE = /\.rbxlx?$/;

function creatorFields() {
	const options = Object.entries(creatorConfigSchema.shape.options.shape);
	const setup = Object.entries(creatorConfigSchema.shape).filter(([name]) => !PROJECT_IDENTITY.has(name));
	return [...options, ...setup];
}

function fieldValues(name, schema) {
	switch (schema.def.type) {
		case "enum":
			return schema.options;
		case "boolean":
			return [true, false];
		case "optional":
			assert.ok(SAMPLE_VALUES[name], `--${name} is optional; add a sample value for it to SAMPLE_VALUES`);
			return [undefined, ...SAMPLE_VALUES[name]];
		default:
			throw new Error(`--${name} has a ${schema.def.type} schema; teach the configuration matrix which values to cover`);
	}
}

function configFor(name, choice) {
	const { git, places, ...options } = choice;
	return { target: path.join(os.tmpdir(), name), name, options: { ...options, ...(places === undefined ? {} : { places }) }, git };
}

function cellName(choice) {
	return [
		choice.mode,
		...(choice.places === undefined ? [] : ["places"]),
		choice.ci ? "ci" : "no-ci",
		choice.agents ? "agents" : "no-agents",
		choice.git ? "git" : "no-git",
	].join("-");
}

function configurationMatrix() {
	let choices = [{}];
	for (const [name, schema] of creatorFields()) {
		choices = choices.flatMap((choice) => fieldValues(name, schema).map((value) => ({ ...choice, [name]: value })));
	}

	return choices
		.map((choice) => ({ choice, name: cellName(choice) }))
		.filter(({ choice, name }) => creatorConfigSchema.safeParse(configFor(name, choice)).success)
		.map(({ choice, name }) => ({
			name,
			choice,
			config: creatorConfigSchema.parse(configFor(name, choice)),
			flags: Object.entries(choice).flatMap(([field, value]) => FLAGS[field](value)),
		}));
}

function placeFiles(project) {
	return fs
		.readdirSync(project, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && PLACE_FILE.test(entry.name))
		.map((entry) => path.relative(project, path.join(entry.parentPath, entry.name)).split(path.sep).join("/"))
		.filter((file) => !file.startsWith("node_modules/"));
}

test("every creator option is covered by the configuration matrix", () => {
	const fields = creatorFields().map(([name]) => name);
	assert.deepEqual(Object.keys(FLAGS).sort(), [...fields].sort(), "each creator option needs a FLAGS entry");

	const matrix = configurationMatrix();
	assert.equal(new Set(matrix.map((cell) => cell.name)).size, matrix.length, "cell names are unique");
	for (const [name, schema] of creatorFields()) {
		for (const value of fieldValues(name, schema)) {
			assert.ok(matrix.some((cell) => cell.choice[name] === value), `no configuration covers --${name} ${JSON.stringify(value)}`);
		}
	}
});

test("every supported configuration generates from the packed creator, installs, builds and checks", { timeout: 3600000 }, async (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-configurations-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));

	const given = process.env.KRF_NPM_TARBALLS;
	const packed = installPackedCreator(root, given ? tarballsIn(given) : packTarballs(path.join(root, "tarballs")));
	const work = path.join(root, "work");

	for (const cell of configurationMatrix()) {
		await t.test(cell.name, () => {
			const { options, git } = cell.config;
			const project = createProject(packed, work, cell.name, cell.flags);
			const generated = Object.keys(readTree(project)).filter((file) => !file.startsWith(".git/"));
			const expected = buildProjectFiles(cell.config);

			assert.deepEqual(generated.filter((file) => !SKILL_DOCS.test(file)).sort(), [...expected.keys()].sort());
			assert.equal(generated.some((file) => SKILL_DOCS.test(file)), options.agents, "the skill ships its reference docs");
			assert.equal(fs.existsSync(path.join(project, ".git")), git);
			assert.equal(generated.includes("AGENTS.md"), options.agents);
			assert.equal(generated.includes(".claude/skills/krf/SKILL.md"), options.agents);
			assert.equal(generated.includes(".github/workflows/ci.yml"), options.ci);
			assert.equal(generated.includes(".github/workflows/release.yml"), options.ci && options.mode === "full");
			assert.equal(generated.some((file) => file.startsWith("world/")), options.mode === "full");
			for (const place of options.places ?? []) {
				assert.ok(generated.some((file) => file.startsWith(`world/${place}/`)), `world/${place}/ is generated`);
			}

			const manifest = JSON.parse(fs.readFileSync(path.join(project, "package.json"), "utf8"));
			assert.deepEqual(manifest.scripts, JSON.parse(expected.get("package.json").toString("utf8")).scripts);
			assert.deepEqual(manifest.devDependencies, { "krf-tools": `file:${packed.tooling.file.split(path.sep).join("/")}` });

			run("npm", ["install"], project);
			run("npm", ["run", "build"], project);
			assert.equal(placeFiles(project).length, options.places?.length ?? 1, "build writes one place file per place");
			run("npm", ["run", "check"], project);
		});
	}
});
