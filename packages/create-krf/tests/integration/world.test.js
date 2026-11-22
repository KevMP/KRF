import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createProject, installPackedCreator, readTree, run } from "./Utils/packedCreator.js";
import { attributes, child, descendant, fixtureItem, inspectBuild, numbers, pathOf, saveStudioPlace, serveTree, shape, walk } from "./Utils/place.js";

const GIT = ["-c", "user.name=KRF Test", "-c", "user.email=krf@example.invalid", "-c", "core.autocrlf=false"];
const STUDIO_OWNED = `<Item class="Folder" referent="RBX0B1C2D3E4F5A6B7C8D9E0F1A2B3C4D01"><Properties><string name="Name">StudioOwned</string></Properties><Item class="Part" referent="RBX0B1C2D3E4F5A6B7C8D9E0F1A2B3C4D02"><Properties><string name="Name">Rock</string><bool name="Anchored">true</bool></Properties></Item></Item>`;

function npm(project, script, args = [], options = {}) {
	const result = run("npm", ["run", "--silent", script, ...(args.length > 0 ? ["--", ...args] : [])], project, options);
	return { status: result.status, out: `${result.stdout}`, err: `${result.stderr}` };
}

function git(project, ...args) {
	return run("git", [...GIT, ...args], project).stdout;
}

function assertArena(place, prefix) {
	const arena = descendant(place, ...prefix, "Arena");
	assert.equal(arena.className, "Model");
	assert.deepEqual(shape(arena), { Floor: "Part", Pillars: "Model", Target: "ObjectValue" });
	assert.deepEqual(
		Object.fromEntries(Object.entries(attributes(arena)).filter(([name]) => !name.startsWith("Rojo_"))),
		{ Difficulty: 3, Lit: true, Theme: "Forest" },
	);

	const floor = child(arena, "Floor");
	assert.equal(place.resolve(arena, "PrimaryPart"), floor, "Model.PrimaryPart still points at Floor");
	assert.equal(place.resolve(child(arena, "Target"), "Value"), floor, "ObjectValue.Value still points at Floor");
	assert.deepEqual(numbers(floor.properties.CFrame), [0, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
	assert.deepEqual(numbers(floor.properties.size), [40, 1, 40]);
	assert.equal(floor.properties.Anchored, "true");

	const pillar = descendant(arena, "Pillars", "Pillar");
	assert.deepEqual(numbers(pillar.properties.CFrame), [10, 7, 10, 0, 0, 1, 0, 1, 0, -1, 0, 0]);
	assert.equal(attributes(pillar).Height, 12.5);
	assert.deepEqual(shape(pillar), { Glow: "PointLight", Sign: "BillboardGui", Sparks: "ParticleEmitter" });
	assert.equal(Number(child(pillar, "Glow").properties.Range), 12);
	assert.equal(Number(child(pillar, "Sparks").properties.Rate), 5);
	const label = descendant(pillar, "Sign", "Label");
	assert.equal(label.className, "TextLabel");
	assert.equal(label.properties.Text, "Arena");
	assert.deepEqual(numbers(child(pillar, "Sign").properties.Size), [0, 200, 0, 50]);
}

function capturedFiles(project, folder) {
	return readTree(path.join(project, ...folder.split("/")));
}

test("a saved Studio place is captured into source and rebuilt from it in both modes", { timeout: 900000 }, async (t) => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "create-krf-world-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const packed = installPackedCreator(root);
	assert.ok(packed.creator.files.includes("templates/full/world/Workspace/Baseplate.model.json"), "the Full starter world must ship");
	assert.ok(packed.creator.files.includes("templates/full/world/Workspace/_gitkeep"), "npm must keep the world folder placeholder");

	await t.test("full", async () => {
		const project = createProject(packed, path.join(root, "work"), "full-world", ["--mode", "full", "--no-ci"]);
		run("npm", ["install"], project);
		assert.match(run("rojo", ["--version"], project).stdout, /Rojo 7\.7\.1/);

		const built = inspectBuild(project, "default.project.json", "built.rbxlx");
		assert.deepEqual(shape(child(built.place, "Workspace")), { Baseplate: "Part", SpawnLocation: "SpawnLocation" });
		assert.deepEqual(numbers(descendant(built.place, "Workspace", "Baseplate").properties.CFrame).slice(0, 3), [0, -8, 0]);
		assert.equal(npm(project, "assets:syncback", ["--input", "build/built.rbxlx"]).out.trim().split("\n").at(-1), "No changes: the captured folders already match the saved place.");

		const studio = saveStudioPlace(built.file, path.join(project, "build", "studio.rbxlx"), [fixtureItem("Arena.rbxmx")]);
		const source = readTree(path.join(project, "src"));
		const captured = npm(project, "assets:syncback", ["--input", "build/studio.rbxlx"]);
		assert.equal(captured.status, 0, captured.err);
		assert.match(captured.out, /Capturing build\/studio\.rbxlx into default\.project\.json \(Full project\)\.\nCaptured trees:\n {2}Workspace -> world\/Workspace\n/);
		assert.match(captured.out, /Captured 1 file change:\n {2}created world\/Workspace\/Arena\.model\.json\n/);
		assert.match(captured.out, /This project has no Git repository/);
		assert.doesNotMatch(captured.out, /git (status|diff)/);
		assert.equal(fs.existsSync(path.join(project, ".git")), false, "capture never initializes Git");
		assert.deepEqual(readTree(path.join(project, "src")), source, "capture never touches code");

		const arenaFile = fs.readFileSync(path.join(project, "world", "Workspace", "Arena.model.json"), "utf8");
		assert.match(arenaFile, /"Rojo_Id": "Workspace\/Arena\/Floor"/);
		assert.doesNotMatch(arenaFile, /[0-9a-f]{32}/, "references use stable names, not per-run ids");

		const world = capturedFiles(project, "world");
		const again = npm(project, "assets:syncback", ["--input", "build/studio.rbxlx"]);
		assert.equal(again.status, 0, again.err);
		assert.match(again.out, /No changes: the captured folders already match the saved place\.\n$/);
		assert.deepEqual(capturedFiles(project, "world"), world, "a second capture of the same place changes nothing");

		run("npm", ["run", "build"], project);
		assertArena(inspectBuild(project, "default.project.json", "rebuilt.rbxlx").place, ["Workspace"]);

		fs.mkdirSync(path.join(project, "assets", "animations"), { recursive: true });
		fs.writeFileSync(path.join(project, "assets", "animations", "Cast.rbxm"), "animation");
		fs.writeFileSync(path.join(project, "assets", "manifest.json"), `${JSON.stringify({ assets: [{ name: "FireballCast", kind: "Animation", id: 1234567890, source: "assets/animations/Cast.rbxm" }] }, null, 2)}\n`);
		assert.notEqual(npm(project, "assets:check", [], { allowFailure: true }).status, 0);
		const written = npm(project, "assets:check", ["--write"]);
		assert.equal(written.status, 0, written.err);
		assert.match(written.out, /Not checked: whether these IDs exist on Roblox/);
		assert.equal(JSON.parse(fs.readFileSync(path.join(project, "assets", "manifest.json"), "utf8")).assets[0].sha256, createHash("sha256").update("animation").digest("hex"));
		assert.match(fs.readFileSync(path.join(project, "src", "shared", "GameAssets.luau"), "utf8"), /^\tFireballCast = "rbxassetid:\/\/1234567890",$/m);
		run("npm", ["run", "check"], project);
		assert.equal(npm(project, "assets:check").status, 0);
	});

	await t.test("hybrid", async () => {
		const project = createProject(packed, path.join(root, "work"), "hybrid-world", ["--mode", "hybrid", "--no-ci"]);
		run("npm", ["install"], project);

		const refused = npm(project, "assets:syncback", ["--input", "missing.rbxl"], { allowFailure: true });
		assert.notEqual(refused.status, 0);
		assert.match(refused.err, /missing\.rbxl does not exist/);

		inspectBuild(project, "start-place.project.json", "start.rbxlx");
		const notOptedIn = npm(project, "assets:syncback", ["--input", "build/start.rbxlx"], { allowFailure: true });
		assert.notEqual(notOptedIn.status, 0);
		assert.match(notOptedIn.err, /maps no world content, so there is nothing to capture\.\nOpt a subtree in/);

		for (const file of ["default.project.json", "start-place.project.json"]) {
			const manifest = JSON.parse(fs.readFileSync(path.join(project, file), "utf8"));
			manifest.tree.Workspace ??= { $className: "Workspace" };
			manifest.tree.Workspace.Arenas = { $path: "world/Workspace/Arenas" };
			fs.writeFileSync(path.join(project, file), `${JSON.stringify(manifest, null, 2)}\n`);
		}
		fs.mkdirSync(path.join(project, "world", "Workspace", "Arenas"), { recursive: true });
		fs.writeFileSync(path.join(project, "world", "Workspace", "Arenas", ".gitkeep"), "");

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
		assert.deepEqual(owned.sort(), ["Folder:Arenas", "Folder:Game", "Folder:Game", "Folder:Packages", "Folder:Shared"], "live sync owns only the opted-in Arenas, never the rest of Workspace");

		const start = inspectBuild(project, "start-place.project.json", "start.rbxlx");
		assert.equal(descendant(start.place, "Workspace", "Arenas").className, "Folder");
		const studio = path.join(project, "hybrid-world.rbxlx");
		saveStudioPlace(start.file, studio, [STUDIO_OWNED]);
		saveStudioPlace(studio, studio, [fixtureItem("Arena.rbxmx")], ["Workspace", "Arenas"]);
		const captured = npm(project, "assets:syncback", ["--input", "hybrid-world.rbxlx"]);
		assert.equal(captured.status, 0, captured.err);
		assert.match(captured.out, /Captured trees:\n {2}Workspace\/Arenas -> world\/Workspace\/Arenas\n/);
		assert.match(captured.out, /Anything else in the place stays only in the place file/);
		const world = capturedFiles(project, "world");
		assert.deepEqual(Object.keys(world).sort(), ["Workspace/Arenas/.gitkeep", "Workspace/Arenas/Arena.model.json"]);
		for (const [file, contents] of Object.entries(world)) {
			assert.ok(file.startsWith("Workspace/Arenas/"), file);
			assert.doesNotMatch(contents, /StudioOwned|Rock|Baseplate|SpawnLocation/, file);
		}

		run("npm", ["run", "build"], project);
		const rebuilt = inspectBuild(project, "start-place.project.json", "rebuilt.rbxlx").place;
		assertArena(rebuilt, ["Workspace", "Arenas"]);
		walk(rebuilt, (node) => assert.notEqual(node.name, "StudioOwned", `${pathOf(node)} is Studio-owned and must not be rebuilt from source`));

		git(project, "init", "--quiet");
		git(project, "add", "-A");
		git(project, "commit", "--quiet", "-m", "Capture the arena");
		const floorFile = path.join(project, "world", "Workspace", "Arenas", "Arena.model.json");
		const localEdit = `${fs.readFileSync(floorFile, "utf8")}\n`;
		fs.writeFileSync(floorFile, localEdit);
		fs.writeFileSync(path.join(project, "NOTES.md"), "unrelated work\n");

		const moved = fs.readFileSync(studio, "utf8").replace("<X>40</X>", "<X>48</X>");
		fs.writeFileSync(studio, moved);
		const conflict = npm(project, "assets:syncback", ["--input", "hybrid-world.rbxlx"], { allowFailure: true });
		assert.notEqual(conflict.status, 0);
		assert.match(conflict.err, /uncommitted changes, so a capture could overwrite them:\n {2}world\/Workspace\/Arenas\/Arena\.model\.json\n/);
		assert.equal(fs.readFileSync(floorFile, "utf8"), localEdit, "a refused capture leaves local edits alone");

		git(project, "checkout", "--", "world");
		const reviewed = npm(project, "assets:syncback", ["--input", "hybrid-world.rbxlx"]);
		assert.equal(reviewed.status, 0, reviewed.err);
		assert.match(reviewed.out, /changed world\/Workspace\/Arenas\/Arena\.model\.json/);
		assert.match(reviewed.out, /Review with git status -- world\/Workspace\/Arenas and git diff -- world\/Workspace\/Arenas, then commit\. Nothing was committed\./);
		assert.deepEqual(
			git(project, "status", "--porcelain").trimEnd().split("\n").sort(),
			["?? NOTES.md", " M world/Workspace/Arenas/Arena.model.json"].sort(),
			"only the captured Floor changed, and unrelated work is untouched",
		);
		assert.equal(git(project, "rev-list", "--count", "HEAD").trim(), "1", "capture never commits");
		assert.equal(fs.readFileSync(path.join(project, "NOTES.md"), "utf8"), "unrelated work\n");
	});
});
