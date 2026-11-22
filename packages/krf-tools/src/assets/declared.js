import { parseJson, stringifyJson } from "./json.js";

const DECLARED = ["$properties", "$attributes"];

const isNode = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const plain = (value) => (value === undefined ? undefined : JSON.parse(stringifyJson(value)));
const same = (left, right) => JSON.stringify(plain(left)) === JSON.stringify(plain(right));

function children(node) {
	return Object.entries(node).filter(([name, child]) => !name.startsWith("$") && isNode(child));
}

function sorted(map) {
	if (!isNode(map) || Object.keys(map).length === 0) return undefined;
	const result = {};
	for (const name of Object.keys(map).sort()) Object.defineProperty(result, name, { value: map[name], enumerable: true, writable: true, configurable: true });
	return result;
}

function changedNames(before, after) {
	const names = [];
	for (const key of DECLARED) {
		const left = isNode(before?.[key]) ? before[key] : {};
		const right = isNode(after?.[key]) ? after[key] : {};
		const label = key === "$attributes" ? (name) => `attribute ${name}` : (name) => name;
		for (const name of new Set([...Object.keys(left), ...Object.keys(right)])) {
			if (!same(left[name], right[name])) names.push(label(name));
		}
	}
	return names.sort();
}

function walk(before, after, prefix, visit) {
	for (const [name, child] of children(before)) {
		const counterpart = after[name];
		if (!isNode(counterpart)) continue;
		const tree = [...prefix, name].join("/");
		visit(tree, child, counterpart);
		walk(child, counterpart, [...prefix, name], visit);
	}
}

function parseTree(text) {
	const project = parseJson(text.replace(/^﻿/, ""));
	if (!isNode(project) || !isNode(project.tree)) throw new SyntaxError("The project has no tree object");
	return project;
}

export function declaredChanges(beforeText, afterText) {
	let before;
	let after;
	try {
		before = parseTree(beforeText);
		after = parseTree(afterText);
	} catch {
		return [];
	}
	const changes = [];
	walk(before.tree, after.tree, [], (tree, left, right) => {
		const names = changedNames(left, right);
		if (names.length > 0) changes.push({ tree, names });
	});
	return changes;
}

function withDeclared(node, values) {
	const result = {};
	const define = (name, value) => Object.defineProperty(result, name, { value, enumerable: true, writable: true, configurable: true });
	const entries = Object.entries(node).filter(([name]) => !DECLARED.includes(name));
	const settings = entries.filter(([name]) => name.startsWith("$"));
	for (const [name, value] of settings) define(name, value);
	for (const key of DECLARED) if (values[key] !== undefined) define(key, values[key]);
	for (const [name, value] of entries.filter(([name]) => !name.startsWith("$"))) define(name, value);
	return result;
}

export function mergeDeclared(projectText, capturedText) {
	let project;
	let captured;
	try {
		project = parseTree(projectText);
		captured = parseTree(capturedText);
	} catch {
		return undefined;
	}

	let changed = false;
	const merge = (node, counterpart) => {
		const result = {};
		for (const [name, value] of Object.entries(node)) {
			const define = (next) => Object.defineProperty(result, name, { value: next, enumerable: true, writable: true, configurable: true });
			if (name.startsWith("$") || !isNode(value) || !isNode(counterpart?.[name])) {
				define(value);
				continue;
			}
			const values = Object.fromEntries(DECLARED.map((key) => [key, sorted(counterpart[name][key])]));
			const differs = DECLARED.some((key) => !same(value[key], values[key]));
			const kept = Object.fromEntries(DECLARED.map((key) => [key, differs ? values[key] : value[key]]));
			if (differs) changed = true;
			define(merge(withDeclared(value, kept), counterpart[name]));
		}
		return result;
	};

	const tree = merge({ tree: project.tree }, { tree: captured.tree }).tree;
	if (!changed) return undefined;
	const eol = projectText.includes("\r\n") ? "\r\n" : "\n";
	const trailing = /\r?\n$/.test(projectText) ? eol : "";
	return `${stringifyJson({ ...project, tree }).replace(/\n/g, eol)}${trailing}`;
}
