import { fileURLToPath } from "node:url";

import { renderTemplate } from "../render.js";
import { CATALOGS } from "./catalogs.js";
import { luaKey, luaNumber, luaString, tableField } from "./luau.js";
import { defaultStateLines, structLines, structTypeLines } from "./schema.js";

const TEMPLATES = fileURLToPath(new URL("../../templates/definitions/", import.meta.url));

const inline = (values) => `{ ${Object.entries(values).map(([field, value]) => `${field} = ${typeof value === "string" ? luaString(value) : luaNumber(value)}`).join(", ")} }`;

const keyedField = (depth, key, entries, valueOf) =>
	entries.length === 0 ? [] : tableField(depth, key, entries.map((entry) => `${luaKey(entry.key)} = ${valueOf(entry)}`), { expand: entries.length > 1 });

const idField = (depth, key, ids) => (ids.length === 0 ? [] : tableField(depth, key, ids.map(luaString)));

const tagApplications = (key, applications) =>
	applications.length === 0
		? []
		: tableField(2, key, applications.map((entry) => (entry.duration === undefined ? luaString(entry.id) : `{ id = ${luaString(entry.id)}, duration = ${luaNumber(entry.duration)} }`)));

function actionLines(options) {
	return [
		...idField(2, "requiredTags", options.requiredTags),
		...idField(2, "blockedTags", options.blockedTags),
		...tagApplications("activeTags", options.activeTags),
		...tagApplications("appliedTags", options.appliedTags),
		...keyedField(2, "resourceRequirements", options.requirements.map((entry) => ({ key: entry.resource, value: entry.requirement })), (entry) => inline(entry.value)),
		...keyedField(
			2,
			"costs",
			options.costs.map((entry) => ({ key: entry.resource, value: entry.cost })),
			(entry) => (Object.keys(entry.value).length === 1 && entry.value.amount !== undefined ? luaNumber(entry.value.amount) : inline(entry.value)),
		),
		...idField(2, "locks", options.locks),
		...idField(2, "interruptibleBy", options.interruptibleBy),
	];
}

const numericSource = (source) => inline(source.value !== undefined ? { value: source.value } : { propertyName: source.propertyName });

function listLines(request) {
	const { options } = request;
	switch (request.kind) {
		case "action":
			return actionLines(options);
		case "tag":
			return keyedField(1, "properties", options.properties.map((entry) => ({ key: entry.property, value: entry.modifier })), (entry) => inline(entry.value));
		case "controller":
			return idField(1, "dependsOn", options.dependsOn);
		case "command":
			return [
				...(options.requestFields.length > 0 ? structLines(1, "request = ", options.requestFields) : []),
				...(options.resultFields.length > 0 ? structLines(1, "result = ", options.resultFields) : []),
			];
		case "hint":
			return structLines(1, "payload = ", options.payloadFields);
		case "domain":
			return [
				...structLines(1, "state = ", options.stateFields),
				...(options.events.length === 0
					? []
					: [
							"\tevents = {",
							...options.events.flatMap((event) =>
								event.fields.length === 0
									? [`\t\t{ id = ${luaString(event.id)}, payload = KRF.Schema.Struct({}) },`]
									: ["\t\t{", `\t\t\tid = ${luaString(event.id)},`, ...structLines(3, "payload = ", event.fields), "\t\t},"],
							),
							"\t},",
						]),
			];
		default:
			return [];
	}
}

export function renderDefinition(request, alias) {
	return renderTemplate(`${TEMPLATES}${request.kind}.luau.ejs`, {
		...request,
		alias,
		lists: listLines(request),
		snapshot: request.kind === "domain" ? defaultStateLines(2, request.options.stateFields) : [],
		numericSource,
		luaString,
		luaNumber,
	});
}

export function renderLoader(kind, alias) {
	return renderTemplate(`${TEMPLATES}loader.luau.ejs`, { catalog: CATALOGS[kind], alias });
}

export function mapEntryLines(key, value) {
	if (!Array.isArray(value)) return [`\t${luaKey(key)} = ${value},`];
	return [`\t${luaKey(key)} = {`, ...value.map((line) => `\t\t${line}`), "\t},"];
}

export function renderMapModule(name, type, entry, alias) {
	return renderTemplate(`${TEMPLATES}request.luau.ejs`, { name, type, entry, alias });
}

const producerLines = (key, fields) => [
	...structTypeLines(`${key} = function(_context: KRF.ActionInputContext): `, fields),
	...defaultStateLines(1, fields),
	"end,",
];

export function needsInputPolicy(options) {
	return options.recipe === "held" || options.startFields.length > 0;
}

export function actionPolicyEntry(options) {
	const held = options.recipe === "held";
	const lines = [
		...(held ? ['activation = "WhileDown",'] : []),
		...(options.startFields.length > 0 ? producerLines("startParameters", options.startFields) : []),
		...(held && options.stopFields.length > 0 ? producerLines("stopParameters", options.stopFields) : []),
	];
	return lines.length === 1 ? `{ ${lines[0].slice(0, -1)} }` : lines;
}

export function actionRequestEntry(options) {
	const held = options.recipe === "held";
	const stop = held || options.clientStop || options.stopFields.length > 0;
	const lines = [
		...(options.startFields.length > 0 ? structLines(0, "start = ", options.startFields) : []),
		...(stop ? (options.stopFields.length > 0 ? ["stop = {", ...structLines(1, "parameters = ", options.stopFields), "},"] : ["stop = {},"]) : []),
		...(held || options.allowInputInterrupt ? ["allowInputInterrupt = true,"] : []),
		...(held ? ["requiresClientRelease = true,"] : []),
		...(held || options.onDisconnect === "Interrupt" ? ['onDisconnect = "Interrupt",'] : []),
	];
	return lines.length === 0 ? "{}" : lines;
}
