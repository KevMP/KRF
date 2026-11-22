import { parseJson, stringifyJson } from "./json.js";

const GENERATED_ID = /^[0-9a-f]{32}$/;
const ID_ATTRIBUTE = "Rojo_Id";
const TARGET_ATTRIBUTE = "Rojo_Target_";
const SORTED_MAPS = ["properties", "attributes"];

function isObject(value) {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function containingRoot(roots, file) {
	return roots.filter((root) => file === root.path || file.startsWith(`${root.path}/`)).sort((left, right) => right.path.length - left.path.length)[0];
}

export function instanceFile(roots, file) {
	const root = containingRoot(roots, file);
	if (root === undefined || !file.endsWith(".json")) return undefined;

	const tree = root.tree.split("/");
	if (file === root.path) return { kind: file.endsWith(".model.json") ? "model" : "meta", path: tree };

	const segments = file.slice(root.path.length + 1).split("/");
	const name = segments.pop();
	if (name === "init.meta.json") return { kind: "meta", path: [...tree, ...segments] };
	if (name.endsWith(".model.json")) return { kind: "model", path: [...tree, ...segments, name.slice(0, -".model.json".length)] };
	if (name.endsWith(".meta.json")) return { kind: "meta", path: [...tree, ...segments, name.slice(0, -".meta.json".length)] };
	return undefined;
}

function instances(document, described) {
	const found = [];
	const visit = (node, path) => {
		if (!isObject(node)) return;
		found.push({ node, path });
		if (described.kind !== "model" || !Array.isArray(node.children)) return;
		for (const child of node.children) {
			if (isObject(child) && typeof child.name === "string") visit(child, [...path, child.name]);
		}
	};
	visit(document, described.path);
	return found;
}

function readDocument(roots, file, contents) {
	const described = instanceFile(roots, file);
	if (described === undefined || contents === undefined) return undefined;
	try {
		const document = parseJson(contents.toString("utf8"));
		return { file, document, instances: instances(document, described) };
	} catch {
		return undefined;
	}
}

function sortMaps(node) {
	for (const key of SORTED_MAPS) {
		if (!isObject(node[key])) continue;
		const sorted = {};
		for (const name of Object.keys(node[key]).sort()) {
			Object.defineProperty(sorted, name, { value: node[key][name], enumerable: true, writable: true, configurable: true });
		}
		node[key] = sorted;
	}
}

function idsOf(document) {
	return document.instances.map(({ node, path }) => ({ node, path: path.join("/"), id: node.attributes?.[ID_ATTRIBUTE] })).filter((entry) => typeof entry.id === "string");
}

export function normalizeCapture({ roots, before, after, changed }) {
	const previous = new Map();
	const previousIds = new Set();
	for (const [file, contents] of [...before].sort(([left], [right]) => (left < right ? -1 : 1))) {
		const document = readDocument(roots, file, contents);
		if (document === undefined) continue;
		for (const { path, id } of idsOf(document)) {
			if (!previous.has(path)) previous.set(path, id);
			previousIds.add(id);
		}
	}

	const rewritten = [...changed]
		.sort()
		.map((file) => readDocument(roots, file, after.get(file)))
		.filter((document) => document !== undefined);
	const rewrittenFiles = new Set(rewritten.map((document) => document.file));

	const used = new Set();
	for (const [file, contents] of after) {
		if (rewrittenFiles.has(file)) continue;
		const document = readDocument(roots, file, contents);
		if (document !== undefined) for (const { id } of idsOf(document)) used.add(id);
	}

	const generated = [];
	for (const document of rewritten) {
		for (const entry of idsOf(document)) {
			if (GENERATED_ID.test(entry.id) && !previousIds.has(entry.id)) generated.push(entry);
			else used.add(entry.id);
		}
	}

	const replacements = new Map();
	for (const { path, id } of generated) {
		if (replacements.has(id)) continue;
		const base = previous.get(path) ?? path;
		let stable = base;
		for (let suffix = 2; used.has(stable); suffix += 1) stable = `${base}~${suffix}`;
		used.add(stable);
		replacements.set(id, stable);
	}

	const results = new Map();
	for (const document of rewritten) {
		for (const { node } of document.instances) {
			sortMaps(node);
			if (!isObject(node.attributes)) continue;
			for (const [name, value] of Object.entries(node.attributes)) {
				if ((name === ID_ATTRIBUTE || name.startsWith(TARGET_ATTRIBUTE)) && replacements.has(value)) node.attributes[name] = replacements.get(value);
			}
		}
		results.set(document.file, stringifyJson(document.document));
	}
	return results;
}
