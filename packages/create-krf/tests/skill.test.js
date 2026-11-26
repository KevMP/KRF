import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KRF_RUNTIME } from "@kevmp/krf-tools";

import { copySkillDocs, rewriteDocument, rewriteLink } from "../scripts/skill-docs.js";
import { buildProjectFiles } from "../src/create.js";

const SKILL = ".agents/skills/krf";
const CLAUDE_SKILL = ".claude/skills/krf";
const AGENT_FILES = (file) => ["AGENTS.md", "CLAUDE.md"].includes(file) || file.startsWith(".agents/") || file.startsWith(".claude/");
const FENCE = /^\s*(```|~~~)/;

const config = (options) => ({ target: "/projects/my-game", name: "my-game", options: { mode: "full", ci: true, agents: true, ...options }, git: false });

function text(files) {
	return new Map([...files].map(([file, contents]) => [file, contents.toString("utf8")]));
}

function writeSkill(t) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-skill-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	for (const [file, contents] of buildProjectFiles(config({}))) {
		if (!AGENT_FILES(file)) continue;
		fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
		fs.writeFileSync(path.join(root, file), contents);
	}
	copySkillDocs({ destination: path.join(root, SKILL, "references", "docs") });
	return path.join(root, SKILL);
}

function markdownFiles(root) {
	return fs
		.readdirSync(root, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
		.map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)).split(path.sep).join("/"))
		.sort();
}

function proseLines(contents) {
	let fenced = false;
	return contents.split("\n").filter((line) => {
		if (FENCE.test(line)) {
			fenced = !fenced;
			return false;
		}
		return !fenced;
	});
}

function links(contents) {
	return proseLines(contents).flatMap((line) =>
		line
			.split(/(`[^`]*`)/)
			.filter((part) => !part.startsWith("`"))
			.flatMap((part) => [...part.matchAll(/\]\(([^)\s]+)\)/g)].map((match) => match[1])),
	);
}

function slug(heading) {
	return heading
		.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/`/g, "")
		.toLowerCase()
		.replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, "")
		.replace(/ /g, "-");
}

function anchors(contents) {
	const found = new Set();
	const seen = new Map();
	for (const line of proseLines(contents)) {
		for (const match of line.matchAll(/<a\s+(?:id|name)="([^"]+)"/g)) found.add(match[1]);
		const heading = /^#{1,6}\s+(.*?)\s*$/.exec(line);
		if (heading === null) continue;
		const explicit = /\s*\{#([^}]+)\}$/.exec(heading[1]);
		if (explicit !== null) {
			found.add(explicit[1]);
			continue;
		}
		const base = slug(heading[1]);
		const count = seen.get(base) ?? 0;
		seen.set(base, count + 1);
		found.add(count === 0 ? base : `${base}-${count}`);
	}
	return found;
}

function frontmatter(contents) {
	const match = /^---\n([\s\S]*?)\n---\n/.exec(contents);
	assert.ok(match, "SKILL.md starts with YAML frontmatter");
	return Object.fromEntries(match[1].split("\n").map((line) => {
		const separator = line.indexOf(": ");
		return [line.slice(0, separator), line.slice(separator + 2)];
	}));
}

test("--agents adds AGENTS.md and the skill, and --no-agents changes nothing else", () => {
	const withAgents = text(buildProjectFiles(config({ agents: true })));
	const withoutAgents = text(buildProjectFiles(config({ agents: false })));

	assert.ok(withAgents.has("AGENTS.md"));
	assert.ok(withAgents.has(`${SKILL}/SKILL.md`));
	assert.ok(withAgents.has(`${SKILL}/references/actions.md`));
	assert.deepEqual([...withoutAgents.keys()].filter(AGENT_FILES), []);
	assert.deepEqual([...withAgents.keys()].filter((file) => !AGENT_FILES(file)), [...withoutAgents.keys()]);

	for (const [file, contents] of withoutAgents) {
		if (file !== "README.md") assert.equal(withAgents.get(file), contents, file);
	}
	assert.match(withAgents.get("README.md"), /`\.agents\/skills\/krf\/` for Codex and `\.claude\/skills\/krf\/` for Claude Code/);
	assert.doesNotMatch(withoutAgents.get("README.md"), /AGENTS\.md|CLAUDE\.md|\.agents|\.claude/);
});

test("Claude Code gets the same skill and imports AGENTS.md", () => {
	const files = text(buildProjectFiles(config({})));
	const skill = [...files.keys()].filter((file) => file.startsWith(`${SKILL}/`));
	const claudeSkill = [...files.keys()].filter((file) => file.startsWith(`${CLAUDE_SKILL}/`));

	assert.ok(skill.length > 0);
	assert.deepEqual(claudeSkill, skill.map((file) => `${CLAUDE_SKILL}/${file.slice(`${SKILL}/`.length)}`));
	for (const file of skill) assert.equal(files.get(`${CLAUDE_SKILL}/${file.slice(`${SKILL}/`.length)}`), files.get(file), file);
	assert.equal(files.get("CLAUDE.md"), "@AGENTS.md\n");
});

test("the skill's frontmatter names it and says when to use it", () => {
	const skill = text(buildProjectFiles(config({}))).get(`${SKILL}/SKILL.md`);
	const fields = frontmatter(skill);

	assert.deepEqual(Object.keys(fields), ["name", "description"]);
	assert.equal(fields.name, "krf");
	assert.ok(fields.description.length > 0 && fields.description.length <= 1024, `${fields.description.length} characters`);
	assert.doesNotMatch(fields.description, /[<>]/);
	assert.match(skill, new RegExp(`describe KRF ${KRF_RUNTIME.version.replaceAll(".", "\\.")}\\.`));
	assert.doesNotMatch(skill, /<%/);
});

test("SKILL.md routes to every reference", () => {
	const files = text(buildProjectFiles(config({})));
	const references = [...files.keys()]
		.filter((file) => /^references\/[^/]+\.md$/.test(file.slice(`${SKILL}/`.length)))
		.map((file) => file.slice(`${SKILL}/`.length));
	const routed = new Set(links(files.get(`${SKILL}/SKILL.md`)).map((target) => target.split("#")[0]));

	assert.ok(references.length > 0);
	assert.deepEqual(references.filter((reference) => !routed.has(reference)), []);
});

test("every link in the skill and its copied docs reaches a file and heading inside the skill", (t) => {
	const root = writeSkill(t);
	const problems = [];

	for (const file of markdownFiles(root)) {
		const contents = fs.readFileSync(path.join(root, file), "utf8");
		for (const target of links(contents)) {
			if (/^(https?|mailto):/.test(target)) continue;
			const [location, anchor] = target.split("#");
			const destination = location === "" ? file : path.posix.normalize(path.posix.join(path.posix.dirname(file), location));
			if (destination.startsWith("../") || path.posix.isAbsolute(destination)) {
				problems.push(`${file}: ${target} leaves the skill`);
				continue;
			}
			if (!fs.existsSync(path.join(root, destination)) || !fs.statSync(path.join(root, destination)).isFile()) {
				problems.push(`${file}: ${target} has no file`);
				continue;
			}
			if (anchor !== undefined && !anchors(fs.readFileSync(path.join(root, destination), "utf8")).has(anchor)) {
				problems.push(`${file}: ${target} has no heading #${anchor}`);
			}
		}
	}

	assert.deepEqual(problems, []);
});

test("copied docs link to pages as files and to the tutorial on the docs site", () => {
	assert.equal(rewriteLink("./api", "actions/guide.md"), "./api.md");
	assert.equal(rewriteLink("../resources/api#resource-definition", "actions/guide.md"), "../resources/api.md#resource-definition");
	assert.equal(rewriteLink("/reference/actions/requests", "getting-started/initialization.md"), "../actions/requests.md");
	assert.equal(rewriteLink("./tags/guide", "index.md"), "./tags/guide.md");
	assert.equal(rewriteLink("/tutorial/test-the-game", "index.md"), "https://kevmp.github.io/KRF/tutorial/test-the-game");
	assert.equal(rewriteLink("/tutorial/", "actors/guide.md"), "https://kevmp.github.io/KRF/tutorial/");
	assert.equal(rewriteLink("#callbacks", "actions/api.md"), "#callbacks");
	assert.equal(rewriteLink("https://create.roblox.com/docs", "index.md"), "https://create.roblox.com/docs");

	assert.equal(
		rewriteDocument("---\ntitle: Tags\n---\n\n# Tags\n\nSee [the API](./api) and `[not](./a link)`.\n\n```lua\nlocal t = x[1](./y)\n```\n", "tags/guide.md"),
		"# Tags\n\nSee [the API](./api.md) and `[not](./a link)`.\n\n```lua\nlocal t = x[1](./y)\n```\n",
	);
});

test("agent files mention only npm scripts the project has", () => {
	for (const options of [{ mode: "full" }, { mode: "hybrid", ci: false }, { mode: "full", places: ["lobby", "dungeon"] }]) {
		const files = text(buildProjectFiles(config(options)));
		const scripts = Object.keys(JSON.parse(files.get("package.json")).scripts);

		for (const [file, contents] of files) {
			if (!AGENT_FILES(file) || !file.endsWith(".md")) continue;
			const mentioned = [...contents.matchAll(/npm run ([A-Za-z:]+)/g)].map((match) => match[1]);
			assert.deepEqual(mentioned.filter((script) => !scripts.includes(script)), [], `${file} ${JSON.stringify(options)}`);
			if (/\bnpm test\b/.test(contents)) assert.ok(scripts.includes("test"), `${file} mentions npm test`);
		}
	}
});
