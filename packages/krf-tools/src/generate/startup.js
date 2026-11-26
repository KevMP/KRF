import { SERVER_STARTUP } from "./catalogs.js";
import { splitLines } from "./luau.js";

const REQUIRE = /^local ([A-Za-z_][A-Za-z0-9_]*) = require\((.+)\)$/;
const SCRIPT_PARENT = /^script\.Parent((?:\.[A-Za-z_][A-Za-z0-9_]*)+)$/;
const FIELD = /^\t([A-Za-z_][A-Za-z0-9_]*) = ([A-Za-z_][A-Za-z0-9_]*),$/;
const ANY_FIELD = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/;

export function readStartup(source, target = SERVER_STARTUP) {
	const initCall = new RegExp(`\\b${target.side}\\.Init\\b`);
	const initOpen = new RegExp(`\\b${target.side}\\.Init\\(\\{$`);
	const { lines, eol } = splitLines(source);
	const requires = new Map();
	lines.forEach((line, index) => {
		const match = REQUIRE.exec(line);
		if (match && !requires.has(match[1])) requires.set(match[1], { index, target: match[2] });
	});

	const opens = lines.flatMap((line, index) => (initCall.test(line) ? [index] : []));
	if (opens.length !== 1 || !initOpen.test(lines[opens[0]])) return { source, lines, eol, requires, target, init: undefined };

	const open = opens[0];
	const close = lines.findIndex((line, index) => index > open && line.startsWith("})"));
	if (close === -1) return { source, lines, eol, requires, target, init: undefined };

	const fields = new Map();
	const present = new Set();
	let simple = lines[close] === "})";
	for (let index = open + 1; index < close; index++) {
		const line = lines[index];
		const field = FIELD.exec(line);
		const any = ANY_FIELD.exec(line);
		if (any && /^\t[A-Za-z_]/.test(line)) present.add(any[1]);
		if (field && target.fields.includes(field[1])) fields.set(field[1], { local: field[2], index });
		else if (line.trim() !== "") simple = false;
	}

	return { source, lines, eol, requires, target, init: { open, close, fields, present, simple } };
}

function folderOfRequire(source, target) {
	const match = SCRIPT_PARENT.exec(target);
	return match ? `${source}${match[1].replace(/\./g, "/")}` : undefined;
}

export function wiringOf(startup, field) {
	if (startup?.init === undefined) return { state: "unknown" };
	if (!startup.init.present.has(field)) return { state: "unwired" };

	const local = startup.init.fields.get(field)?.local;
	const folder = local === undefined ? undefined : folderOfRequire(startup.target.source, startup.requires.get(local)?.target ?? "");
	return folder === undefined ? { state: "custom" } : { state: "wired", folder };
}

export function startupLines(catalog) {
	return {
		require: `local ${catalog.folder} = require(script.Parent.${catalog.folder})`,
		field: `\t${catalog.field} = ${catalog.folder},`,
	};
}

export function addCatalog(startup, catalog) {
	const init = startup?.init;
	if (init === undefined || !init.simple || init.present.has(catalog.field)) return undefined;
	if (new RegExp(`\\b${catalog.folder}\\b`).test(startup.source)) return undefined;

	const requireIndices = [...startup.requires.values()].map((entry) => entry.index).sort((left, right) => left - right);
	if (requireIndices.length === 0 || requireIndices.at(-1) - requireIndices[0] !== requireIndices.length - 1 || requireIndices.at(-1) > init.open) {
		return undefined;
	}

	const { require, field } = startupLines(catalog);
	const lines = [...startup.lines];

	const orderedFields = startup.target.fields;
	const fieldOrder = orderedFields.indexOf(catalog.field);
	const after = [...init.fields.entries()].filter(([name]) => orderedFields.indexOf(name) > fieldOrder).map(([, entry]) => entry.index);
	lines.splice(after.length > 0 ? Math.min(...after) : init.close, 0, field);

	const siblings = [...startup.requires.entries()].filter(([, entry]) => folderOfRequire(startup.target.source, entry.target) !== undefined);
	const later = siblings.filter(([name]) => name > catalog.folder).map(([, entry]) => entry.index);
	const requireAt = later.length > 0 ? Math.min(...later) : (siblings.length > 0 ? Math.max(...siblings.map(([, entry]) => entry.index)) : requireIndices.at(-1)) + 1;
	lines.splice(requireAt, 0, require);

	return lines.join(startup.eol);
}
