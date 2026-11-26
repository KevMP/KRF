const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const REFERENCES = path.join(ROOT, "packages/create-krf/templates/agents/_agents/skills/krf/references");
const FIXTURES = path.join(ROOT, "packages/create-krf/tests/fixtures/skill-examples");
const SOURCE = path.join(ROOT, "src");
const PLACEHOLDER = /^(\t*)--@example (\d+)$/;
const SIDES = {
	server: ["ServerScriptService"],
	shared: ["ReplicatedStorage"],
	client: ["StarterPlayer", "StarterPlayerScripts"],
};

function luauExamples(markdown) {
	const examples = [];
	let current = null;

	for (const line of markdown.replace(/\r\n/g, "\n").split("\n")) {
		if (current === null) {
			if (/^```lua\s*$/.test(line)) current = [];
		} else if (/^```\s*$/.test(line)) {
			examples.push(current);
			current = null;
		} else {
			current.push(line);
		}
	}

	return examples;
}

function listFiles(root) {
	if (!fs.existsSync(root)) return [];
	return fs
		.readdirSync(root, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile())
		.map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)))
		.sort();
}

function placeExamples(reference, examples, fixture, output, problems) {
	const uses = examples.map(() => 0);

	for (const file of listFiles(fixture)) {
		const lines = fs.readFileSync(path.join(fixture, file), "utf8").replace(/\r\n/g, "\n").split("\n");
		const placed = lines.flatMap((line) => {
			const match = PLACEHOLDER.exec(line);
			if (match === null) return [line];

			const index = Number(match[2]) - 1;
			if (examples[index] === undefined) {
				problems.push(`${reference}: ${file} places example ${match[2]}, but the reference has ${examples.length}`);
				return [];
			}

			uses[index] += 1;
			return examples[index].map((exampleLine) => (exampleLine === "" ? "" : `${match[1]}${exampleLine}`));
		});

		fs.mkdirSync(path.dirname(path.join(output, file)), { recursive: true });
		fs.writeFileSync(path.join(output, file), placed.join("\n"));
	}

	uses.forEach((count, index) => {
		if (count !== 1) problems.push(`${reference}: example ${index + 1} is placed ${count} times; place it exactly once`);
	});
}

function mount(tree, segments, name, target) {
	let node = tree;
	for (const segment of segments) node = node[segment] ??= { $className: segment };
	node[name] = { $path: target };
}

function prepareSkillExamples(output) {
	fs.rmSync(output, { recursive: true, force: true });
	fs.mkdirSync(output, { recursive: true });

	const problems = [];
	const relative = (target) => path.relative(output, target).split(path.sep).join("/");
	const tree = {
		$className: "DataModel",
		ReplicatedStorage: { $className: "ReplicatedStorage", Packages: { $className: "Folder", KRF: { $path: relative(SOURCE) } } },
	};
	const references = fs.readdirSync(REFERENCES).filter((file) => file.endsWith(".md")).map((file) => file.slice(0, -".md".length)).sort();

	for (const reference of references) {
		const examples = luauExamples(fs.readFileSync(path.join(REFERENCES, `${reference}.md`), "utf8"));
		const fixture = path.join(FIXTURES, reference);
		if (examples.length === 0 && !fs.existsSync(fixture)) continue;
		if (!fs.existsSync(fixture)) {
			problems.push(`${reference}: ${examples.length} Luau examples have no fixture in ${relative(fixture)}`);
			continue;
		}

		placeExamples(reference, examples, fixture, path.join(output, reference), problems);
		for (const [side, segments] of Object.entries(SIDES)) {
			if (fs.existsSync(path.join(fixture, side))) mount(tree, segments, reference, `${reference}/${side}`);
		}
	}

	for (const fixture of fs.readdirSync(FIXTURES)) {
		if (!references.includes(fixture)) problems.push(`${fixture}: the fixture has no matching reference`);
	}

	if (problems.length > 0) throw new Error(`Skill examples are not checkable:\n${problems.join("\n")}`);

	const project = path.join(output, "skill-examples.project.json");
	fs.writeFileSync(project, `${JSON.stringify({ name: "skill-examples", tree }, null, 2)}\n`);
	fs.writeFileSync(path.join(output, ".luaurc"), `${JSON.stringify({ languageMode: "strict", lint: { "*": false } }, null, 2)}\n`);

	return { project, sourcemap: path.join(output, "sourcemap.json") };
}

module.exports = { luauExamples, prepareSkillExamples };
