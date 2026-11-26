import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { KRF_RUNTIME } from "krf-tools";

import { PACKAGES, createProject, generateDefinitions, installPackedCreator, readTree, run } from "./Utils/packedCreator.js";
import { child, inspectBuild, serveTree, shape, walk } from "./Utils/place.js";

const VARIANTS = [
	{ mode: "full", flags: ["--ci"], agents: true },
	{ mode: "hybrid", flags: ["--no-ci", "--no-agents"], agents: false },
];

const LEAKED_NAMES = /^(tests?|spec|jest|DevPackages|node_modules|package|krf-tools|coverage|.github)$|.spec$|.test$/i;

test("packed create-krf projects install the published KRF, check and build in every mode", { timeout: 900000 }, async (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-pack-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));

	const packed = installPackedCreator(root);
	assert.ok(packed.creator.files.includes("templates/base/_gitignore"), "npm must keep the gitignore template");
	assert.ok(packed.creator.files.includes("templates/base/src/server/Startup.server.luau"));
	assert.ok(packed.creator.files.includes("templates/base/_vscode/settings.json.ejs"));
	assert.ok(packed.creator.files.includes("templates/agents/_agents/skills/krf/SKILL.md.ejs"));
	assert.ok(packed.creator.files.includes("templates/agents/_agents/skills/krf/references/docs/actions/guide.md"), "the skill must ship the reference docs");
	assert.equal(fs.existsSync(path.join(PACKAGES, "create-krf", "templates", "agents", "_agents", "skills", "krf", "references", "docs")), false, "packing must not leave the copied docs behind");
	assert.ok(!packed.creator.files.some((file) => file.startsWith("scripts/")), "pack scripts must not ship");
	assert.ok(!packed.creator.files.some((file) => file.startsWith("tests/")), "tests must not ship");
	assert.ok(!packed.tooling.files.some((file) => file.startsWith("tests/")), "tests must not ship");
	assert.ok(packed.tooling.files.includes("bin/krf-tools.js"), "the generator executable must ship");
	assert.ok(packed.tooling.files.includes("templates/definitions/action.luau.ejs"), "definition templates must ship");
	assert.equal(fs.lstatSync(path.join(packed.installRoot, "node_modules", "krf-tools")).isSymbolicLink(), false);

	for (const variant of VARIANTS) {
		await t.test(variant.mode, async () => {
			const name = variant.mode;
			const project = createProject(packed, path.join(root, "work"), name, ["--mode", variant.mode, ...variant.flags]);
			const generated = readTree(project);
			const manifest = JSON.parse(generated["package.json"]);
			assert.deepEqual(manifest.devDependencies, { "krf-tools": `file:${packed.tooling.file.split(path.sep).join("/")}` }, "the project installs the krf-tools tarball the creator came from");
			assert.equal(fs.existsSync(path.join(project, "node_modules")), false);
			assert.equal("AGENTS.md" in generated, variant.agents);
			assert.equal(".agents/skills/krf/references/docs/actions/guide.md" in generated, variant.agents);
			assert.equal(".claude/skills/krf/references/docs/actions/guide.md" in generated, variant.agents);
			assert.equal(Object.keys(generated).some((file) => file.startsWith(".agents/")), variant.agents);

			run("npm", ["install"], project);
			assert.equal(generated["wally.lock"], undefined, "Wally writes the lockfile, not the creator");
			assert.match(fs.readFileSync(path.join(project, "wally.lock"), "utf8"), new RegExp(`^name = "${KRF_RUNTIME.package}"\nversion = "${KRF_RUNTIME.version}"$`, "m"));
			assert.match(fs.readFileSync(path.join(project, "Packages", "KRF.lua"), "utf8"), /export type ServerStartConfig = REQUIRED_MODULE\.ServerStartConfig/);

			generateDefinitions(project);
			const generatedSource = readTree(path.join(project, "src"));
			run("npm", ["run", "check"], project);
			assert.deepEqual(readTree(path.join(project, "src")), generatedSource, "generated modules are already formatted");

			const startProject = variant.mode === "hybrid" ? "start-place.project.json" : "default.project.json";
			run("npm", ["run", "build"], project);
			assert.ok(fs.statSync(path.join(project, ...(variant.mode === "hybrid" ? ["build", `${name}.rbxl`] : [`${name}.rbxl`]))).size > 0);

			const place = inspectBuild(project, startProject).place;
			const replicated = child(place, "ReplicatedStorage");
			const packages = child(replicated, "Packages");
			assert.equal(child(packages, "KRF").className, "ModuleScript");
			const krf = child(child(child(packages, "_Index"), `kevmp_krf@${KRF_RUNTIME.version}`), "krf");
			assert.deepEqual(Object.keys(shape(krf)).sort(), ["client", "server", "shared"]);
			const shared = child(replicated, "Shared");
			assert.deepEqual(shape(shared), { ActionRequests: "ModuleScript", MergeDescendants: "ModuleScript", RequireDescendants: "ModuleScript" });
			assert.deepEqual(shape(child(shared, "ActionRequests")), { Fireball: "ModuleScript", Focus: "ModuleScript", Guard: "ModuleScript", Ward: "ModuleScript" });

			const server = child(child(place, "ServerScriptService"), "Game");
			assert.deepEqual(shape(server), {
				Actions: "ModuleScript",
				Commands: "ModuleScript",
				Controllers: "ModuleScript",
				Hints: "ModuleScript",
				PlayerActors: "ModuleScript",
				Properties: "ModuleScript",
				ReplicationDomains: "ModuleScript",
				Resources: "ModuleScript",
				Startup: "Script",
				Tags: "ModuleScript",
			});
			assert.deepEqual(shape(child(server, "Actions")), { Combat: "Folder", Fireball: "ModuleScript", Focus: "ModuleScript", Guard: "ModuleScript", Ward: "ModuleScript" });
			assert.deepEqual(shape(child(child(server, "Actions"), "Combat")), { Meditate: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Tags")), { Burning: "ModuleScript", Focused: "ModuleScript", Stunned: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Properties")), { EnergyRegen: "ModuleScript", ManaRegen: "ModuleScript", MaxMana: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Resources")), { Energy: "ModuleScript", Mana: "ModuleScript", Stamina: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Controllers")), { Cooldowns: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Commands")), { CastSpell: "ModuleScript", Trade: "ModuleScript" });
			assert.deepEqual(shape(child(server, "Hints")), { ImpactFx: "ModuleScript", Ping: "ModuleScript" });
			assert.deepEqual(shape(child(server, "ReplicationDomains")), { ComboState: "ModuleScript" });

			const client = child(child(child(place, "StarterPlayer"), "StarterPlayerScripts"), "Game");
			assert.deepEqual(shape(client), {
				ActionInputPolicies: "ModuleScript",
				Controls: "ModuleScript",
				EnergyDisplay: "ModuleScript",
				LocalCharacter: "ModuleScript",
				Startup: "LocalScript",
			});
			assert.deepEqual(shape(child(client, "ActionInputPolicies")), { Focus: "ModuleScript", Guard: "ModuleScript", Ward: "ModuleScript" });
			assert.deepEqual(shape(child(place, "Workspace")), { Baseplate: "Part", SpawnLocation: "SpawnLocation" });

			walk(place, (node) => assert.doesNotMatch(node.name ?? "", LEAKED_NAMES, `unexpected ${node.className} ${node.name} in the place`));

			const energy = path.join(project, "src", "server", "Resources", "Energy.luau");
			fs.writeFileSync(energy, fs.readFileSync(energy, "utf8").replace("max = { value = 100 }", "max = { value = 120 }"));
			const rebuilt = inspectBuild(project, startProject).place;
			assert.match(child(child(child(child(rebuilt, "ServerScriptService"), "Game"), "Resources"), "Energy").source, /max = \{ value = 120 \}/);

			if (variant.mode === "hybrid") {
				const live = inspectBuild(project, "default.project.json").place;
				assert.equal(live.children.some((node) => node.name === "Workspace"), false, "Hybrid live sync must not own the world");

				const served = await serveTree(project);
				const owned = [];
				const visit = (id, insideOwned) => {
					const instance = served.instances[id];
					const ownsChildren = instance.Metadata.ignoreUnknownInstances === false;
					if (!insideOwned) {
						if (ownsChildren) owned.push(`${instance.ClassName}:${instance.Name}`);
						else assert.equal(instance.Metadata.ignoreUnknownInstances, true, `${instance.Name} would delete Studio content`);
					}
					for (const childId of instance.Children) visit(childId, insideOwned || ownsChildren);
				};
				visit(served.rootId, false);
				assert.deepEqual(owned.sort(), ["Folder:Game", "Folder:Game", "Folder:Packages", "Folder:Shared"]);
			}
		});
	}
});
