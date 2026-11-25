import assert from "node:assert/strict";
import test from "node:test";

import { JsonNumber, parseJson, stringifyJson } from "../src/world/json.js";
import { instanceFile, normalizeCapture } from "../src/world/normalize.js";

const ROOTS = [{ tree: "Workspace", path: "world/Workspace" }];
const GENERATED = "4b14589832b6fd28caf1b59c00000000";
const REGENERATED = "5d175369ad720863caf1b59c00000000";

const rojo = (value) => Buffer.from(stringifyJson(value));

function arena(id, order = ["Size", "Anchored"]) {
	const properties = Object.fromEntries(order.map((name) => [name, name === "Size" ? [new JsonNumber("40.0"), new JsonNumber("1.0"), new JsonNumber("40.0")] : true]));
	return {
		className: "Model",
		children: [
			{ name: "Floor", className: "Part", properties, attributes: { Rojo_Id: id } },
			{ name: "Target", className: "ObjectValue", attributes: { Rojo_Target_Value: id } },
		],
		attributes: { Theme: "Forest", Rojo_Target_PrimaryPart: id, Difficulty: new JsonNumber("3.0") },
	};
}

function normalize(before, after) {
	const changed = new Set([...after.keys()].filter((file) => !before.has(file) || !before.get(file).equals(after.get(file))));
	return normalizeCapture({ roots: ROOTS, before, after, changed });
}

test("captured JSON keeps Rojo's number text and pretty-printing", () => {
	const text = '{\n  "className": "Part",\n  "properties": {\n    "Size": [\n      512.0,\n      1e-7,\n      -0.707099974155426\n    ],\n    "Tags": [],\n    "Empty": {}\n  }\n}';
	assert.equal(stringifyJson(parseJson(text)), text);
	assert.equal(parseJson('{"__proto__": 1}').__proto__.raw, "1");
	assert.throws(() => parseJson('{"a": 1,}'), SyntaxError);
	assert.throws(() => parseJson("[1] 2"), SyntaxError);
});

test("JSON files under a captured root describe instances by their place path", () => {
	assert.deepEqual(instanceFile(ROOTS, "world/Workspace/Arena.model.json"), { kind: "model", path: ["Workspace", "Arena"] });
	assert.deepEqual(instanceFile(ROOTS, "world/Workspace/Arena/init.meta.json"), { kind: "meta", path: ["Workspace", "Arena"] });
	assert.deepEqual(instanceFile(ROOTS, "world/Workspace/Arena/Door.meta.json"), { kind: "meta", path: ["Workspace", "Arena", "Door"] });
	assert.deepEqual(instanceFile([{ tree: "Workspace/Arena", path: "world/Arena.model.json" }], "world/Arena.model.json"), { kind: "model", path: ["Workspace", "Arena"] });
	assert.equal(instanceFile(ROOTS, "world/Workspace/Door.server.luau"), undefined);
	assert.equal(instanceFile(ROOTS, "src/Arena.model.json"), undefined);
});

test("a new capture sorts property and attribute maps and names generated references by place path", () => {
	const result = normalize(new Map(), new Map([["world/Workspace/Arena.model.json", rojo(arena(GENERATED))]]));
	const document = JSON.parse(result.get("world/Workspace/Arena.model.json"));
	assert.deepEqual(Object.keys(document.children[0].properties), ["Anchored", "Size"]);
	assert.deepEqual(Object.keys(document.attributes), ["Difficulty", "Rojo_Target_PrimaryPart", "Theme"]);
	assert.equal(document.children[0].attributes.Rojo_Id, "Workspace/Arena/Floor");
	assert.equal(document.children[1].attributes.Rojo_Target_Value, "Workspace/Arena/Floor");
	assert.equal(document.attributes.Rojo_Target_PrimaryPart, "Workspace/Arena/Floor");
	assert.match(result.get("world/Workspace/Arena.model.json"), /"Difficulty": 3\.0,/);
});

test("recapturing an unchanged place reproduces the previous bytes despite new ids and map order", () => {
	const first = normalize(new Map(), new Map([["world/Workspace/Arena.model.json", rojo(arena(GENERATED))]]));
	const before = new Map([["world/Workspace/Arena.model.json", Buffer.from(first.get("world/Workspace/Arena.model.json"))]]);
	const second = normalize(before, new Map([["world/Workspace/Arena.model.json", rojo(arena(REGENERATED, ["Anchored", "Size"]))]]));
	assert.equal(second.get("world/Workspace/Arena.model.json"), first.get("world/Workspace/Arena.model.json"));
});

test("an instance keeps the id it had at the same path, and new ids never collide", () => {
	const before = new Map([
		["world/Workspace/Arena.model.json", rojo(arena("arena-floor"))],
		["world/Workspace/Marker.model.json", rojo({ className: "Part", attributes: { Rojo_Id: "Workspace/Copy/Floor" } })],
	]);
	const after = new Map([
		...before,
		["world/Workspace/Arena.model.json", rojo(arena(GENERATED))],
		["world/Workspace/Copy.model.json", rojo({ className: "Model", children: [{ name: "Floor", className: "Part", attributes: { Rojo_Id: REGENERATED } }] })],
	]);

	const result = normalize(before, after);
	assert.equal(JSON.parse(result.get("world/Workspace/Arena.model.json")).children[0].attributes.Rojo_Id, "arena-floor");
	assert.equal(JSON.parse(result.get("world/Workspace/Copy.model.json")).children[0].attributes.Rojo_Id, "Workspace/Copy/Floor~2");
	assert.equal(result.has("world/Workspace/Marker.model.json"), false);
});

test("references across files are renamed together, and ids held outside JSON files are left alone", () => {
	const after = new Map([
		["world/Workspace/Arena/Floor.model.json", rojo({ className: "Part", attributes: { Rojo_Id: GENERATED } })],
		["world/Workspace/Arena/Target.model.json", rojo({ className: "ObjectValue", attributes: { Rojo_Target_Value: GENERATED } })],
		["world/Workspace/Pointer.model.json", rojo({ className: "ObjectValue", attributes: { Rojo_Target_Value: REGENERATED } })],
	]);
	const result = normalize(new Map(), after);
	assert.equal(JSON.parse(result.get("world/Workspace/Arena/Target.model.json")).attributes.Rojo_Target_Value, "Workspace/Arena/Floor");
	assert.equal(JSON.parse(result.get("world/Workspace/Pointer.model.json")).attributes.Rojo_Target_Value, REGENERATED);
});

test("ids that existed before the capture and unreadable files are not rewritten", () => {
	const before = new Map([["world/Workspace/Old.model.json", rojo({ className: "Part", attributes: { Rojo_Id: GENERATED } })]]);
	const after = new Map([
		["world/Workspace/Old.model.json", rojo({ className: "Part", properties: { B: true, A: true }, attributes: { Rojo_Id: GENERATED } })],
		["world/Workspace/Broken.model.json", Buffer.from("{ not json")],
	]);
	const result = normalize(before, after);
	assert.equal(JSON.parse(result.get("world/Workspace/Old.model.json")).attributes.Rojo_Id, GENERATED);
	assert.equal(result.has("world/Workspace/Broken.model.json"), false);
});
