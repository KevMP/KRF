import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { decode } from "@msgpack/msgpack";

import { run } from "./packedCreator.js";

export const FIXTURES = fileURLToPath(new URL("../fixtures/", import.meta.url));

const TOKEN = /<Item class="([^"]+)"(?: referent="([^"]+)")?>|<\/Item>|<(\w+) name="([^"]+)">([\s\S]*?)<\/\3>|<(\w+) name="([^"]+)"\s*\/>/g;
const CDATA = /^<!\[CDATA\[([\s\S]*)\]\]>$/;

export function readPlace(xml) {
	const root = { className: "DataModel", name: "DataModel", children: [], properties: {} };
	const stack = [root];
	const byReferent = new Map();

	for (const match of xml.matchAll(TOKEN)) {
		const current = stack.at(-1);
		if (match[1] !== undefined) {
			const item = { className: match[1], referent: match[2], name: undefined, parent: current, children: [], properties: {} };
			current.children.push(item);
			stack.push(item);
			if (match[2] !== undefined) byReferent.set(match[2], item);
		} else if (match[0] === "</Item>") {
			stack.pop();
		} else {
			const name = match[4] ?? match[7];
			const text = match[5] ?? "";
			current.properties[name] = text;
			if (name === "Name" && current.name === undefined) current.name = text;
			if (name === "Source") current.source = CDATA.exec(text)?.[1] ?? text;
		}
	}

	const resolve = (node, property) => byReferent.get(node.properties[property]);
	return Object.assign(root, { resolve });
}

export function inspectBuild(project, projectFile, output = "inspect.rbxlx") {
	const file = path.join(project, "build", output);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	run("rojo", ["build", projectFile, "--output", file], project);
	return { file, place: readPlace(fs.readFileSync(file, "utf8")) };
}

export function child(node, name) {
	const found = node.children.find((candidate) => candidate.name === name);
	assert.ok(found, `${node.name} has no child ${name}; children: ${node.children.map((entry) => entry.name).join(", ")}`);
	return found;
}

export function descendant(node, ...names) {
	return names.reduce(child, node);
}

export function shape(node) {
	return Object.fromEntries(node.children.map((entry) => [entry.name, entry.className]));
}

export function walk(node, visit) {
	visit(node);
	for (const entry of node.children) walk(entry, visit);
}

export function pathOf(node) {
	const names = [];
	for (let current = node; current?.parent !== undefined; current = current.parent) names.unshift(current.name);
	return names.join("/");
}

export function numbers(text) {
	return [...text.matchAll(/<\w+>([^<]*)<\/\w+>/g)].map((match) => Number(match[1]));
}

export function attributes(node) {
	const text = node.properties.AttributesSerialize;
	if (text === undefined || text === "") return {};
	const bytes = Buffer.from(text, "base64");
	let offset = 0;
	const u32 = () => {
		const value = bytes.readUInt32LE(offset);
		offset += 4;
		return value;
	};
	const string = () => {
		const length = u32();
		const value = bytes.toString("utf8", offset, offset + length);
		offset += length;
		return value;
	};

	const decoded = {};
	for (let count = u32(); count > 0; count -= 1) {
		const name = string();
		const type = bytes[offset++];
		if (type === 0x02) decoded[name] = string();
		else if (type === 0x03) decoded[name] = bytes[offset++] === 1;
		else if (type === 0x06) {
			decoded[name] = bytes.readDoubleLE(offset);
			offset += 8;
		} else throw new Error(`Unsupported attribute type ${type} for ${name}`);
	}
	return decoded;
}

export function fixtureItem(name) {
	const xml = fs.readFileSync(path.join(FIXTURES, name), "utf8");
	return xml.slice(xml.indexOf("<Item"), xml.lastIndexOf("</Item>") + "</Item>".length);
}

export function saveStudioPlace(source, output, items, parent = ["Workspace"]) {
	const xml = fs.readFileSync(source, "utf8");
	const target = descendant(readPlace(xml), ...parent);
	const opening = `<Item class="${target.className}" referent="${target.referent}">`;
	const at = xml.indexOf("</Properties>", xml.indexOf(opening)) + "</Properties>".length;
	assert.ok(xml.includes(opening) && at > opening.length, `${parent.join("/")} has no properties in the built place`);
	fs.writeFileSync(output, `${xml.slice(0, at)}\n${items.join("\n")}${xml.slice(at)}`);
	return output;
}

async function readApi(url) {
	const response = await fetch(url);
	return decode(new Uint8Array(await response.arrayBuffer()));
}

export async function serveTree(project) {
	const port = 34000 + Math.floor(Math.random() * 1000);
	const server = spawn("rojo", ["serve", "default.project.json", "--port", String(port)], { cwd: project, stdio: "ignore" });

	try {
		let info;
		for (let attempt = 0; attempt < 100 && info === undefined; attempt++) {
			await new Promise((resolve) => setTimeout(resolve, 200));
			info = await readApi(`http://127.0.0.1:${port}/api/rojo`).catch(() => undefined);
		}
		assert.ok(info, "rojo serve did not start");

		const read = await readApi(`http://127.0.0.1:${port}/api/read/${info.rootInstanceId}`);
		return { rootId: info.rootInstanceId, instances: read.instances };
	} finally {
		server.kill();
	}
}
