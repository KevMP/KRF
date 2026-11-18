import { isIdentifier, luaString } from "./luau.js";

const PRIMITIVES = new Set(["Boolean", "U8", "U16", "U32", "I8", "I16", "I32", "F32", "F64"]);
const ENUM_VALUE = /^[A-Za-z][A-Za-z0-9_]*$/;
const COUNT = /^[1-9][0-9]*$/;

export const SCHEMA_TYPES_HELP = "Boolean, U8, U16, U32, I8, I16, I32, F32, F64, String(maxBytes), Enum(A|B), Optional(Type), Array(Type,maxLength) or Map(KeyType,ValueType,maxEntries)";

export function splitTopLevel(text, separator = ",") {
	const parts = [];
	let depth = 0;
	let current = "";
	for (const character of text) {
		if (character === "(") depth += 1;
		if (character === ")") depth -= 1;
		if (character === separator && depth === 0) {
			parts.push(current);
			current = "";
		} else {
			current += character;
		}
	}
	parts.push(current);
	return parts.map((part) => part.trim());
}

function fail(message) {
	throw new SyntaxError(message);
}

function count(text, what) {
	if (!COUNT.test(text ?? "")) fail(`${what} must be a whole number of at least 1, not '${text ?? ""}'`);
	return Number(text);
}

function parseType(text) {
	const source = text.trim();
	if (PRIMITIVES.has(source)) return { kind: source };

	const call = /^([A-Za-z]+)\((.*)\)$/.exec(source);
	if (!call) fail(`'${source}' is not a schema type; use ${SCHEMA_TYPES_HELP}`);

	const [, kind, inner] = call;
	const args = splitTopLevel(inner);
	switch (kind) {
		case "String":
			if (args.length !== 1) fail("String takes one argument: String(maxBytes)");
			return { kind, maxBytes: count(args[0], "String maxBytes") };
		case "Enum": {
			const values = inner.split("|").map((value) => value.trim());
			if (values.length === 0 || values.some((value) => !ENUM_VALUE.test(value))) fail(`Enum values must be names separated by '|', such as Enum(Fire|Ice), not '${inner}'`);
			if (new Set(values).size !== values.length) fail(`Enum(${inner}) lists a value twice`);
			return { kind, values };
		}
		case "Optional":
			if (args.length !== 1) fail("Optional takes one type: Optional(Type)");
			return { kind, inner: parseType(args[0]) };
		case "Array":
			if (args.length !== 2) fail("Array takes a type and a maximum length: Array(Type,maxLength)");
			return { kind, element: parseType(args[0]), maxLength: count(args[1], "Array maxLength") };
		case "Map":
			if (args.length !== 3) fail("Map takes a key type, a value type and a maximum size: Map(KeyType,ValueType,maxEntries)");
			return { kind, key: parseType(args[0]), value: parseType(args[1]), maxEntries: count(args[2], "Map maxEntries") };
		default:
			return fail(`'${kind}' is not a schema type; use ${SCHEMA_TYPES_HELP}`);
	}
}

export function parseFields(specs) {
	const fields = [];
	for (const spec of specs) {
		const separator = spec.indexOf(":");
		const name = separator === -1 ? spec.trim() : spec.slice(0, separator).trim();
		if (separator === -1 || !isIdentifier(name)) fail(`'${spec}' must be Name:Type, such as Amount:U8`);
		if (fields.some((field) => field.name === name)) fail(`'${name}' is listed twice`);
		fields.push({ name, type: parseType(spec.slice(separator + 1)) });
	}
	return fields;
}

export function parseEvent(spec) {
	const match = /^([^()]+?)(?:\((.*)\))?$/.exec(spec.trim());
	if (!match) fail(`'${spec}' must be EventId or EventId(Name:Type,...), such as Hit(Damage:U16)`);
	return { id: match[1].trim(), fields: match[2] === undefined || match[2].trim() === "" ? [] : parseFields(splitTopLevel(match[2])) };
}

export function renderType(type) {
	switch (type.kind) {
		case "String":
			return `KRF.Schema.String(${type.maxBytes})`;
		case "Enum":
			return `KRF.Schema.Enum({ ${type.values.map(luaString).join(", ")} })`;
		case "Optional":
			return `KRF.Schema.Optional(${renderType(type.inner)})`;
		case "Array":
			return `KRF.Schema.Array(${renderType(type.element)}, ${type.maxLength})`;
		case "Map":
			return `KRF.Schema.Map(${renderType(type.key)}, ${renderType(type.value)}, ${type.maxEntries})`;
		default:
			return `KRF.Schema.${type.kind}`;
	}
}

export function structLines(depth, prefix, fields, suffix = ",") {
	const indent = "\t".repeat(depth);
	if (fields.length === 0) return [`${indent}${prefix}KRF.Schema.Struct({})${suffix}`];
	return [`${indent}${prefix}KRF.Schema.Struct({`, ...fields.map((field) => `${indent}\t${field.name} = ${renderType(field.type)},`), `${indent}})${suffix}`];
}

function luauType(type) {
	switch (type.kind) {
		case "Boolean":
			return "boolean";
		case "String":
			return "string";
		case "Enum":
			return type.values.map(luaString).join(" | ");
		case "Optional": {
			const inner = luauType(type.inner);
			const union = type.inner.kind === "Optional" || (type.inner.kind === "Enum" && type.inner.values.length > 1);
			return union ? `(${inner})?` : `${inner}?`;
		}
		case "Array":
			return `{ ${luauType(type.element)} }`;
		case "Map":
			return `{ [${luauType(type.key)}]: ${luauType(type.value)} }`;
		default:
			return "number";
	}
}

export function structTypeLines(prefix, fields, suffix = "") {
	if (fields.length === 0) return [`${prefix}{}${suffix}`];
	return [`${prefix}{`, ...fields.map((field) => `\t${field.name}: ${luauType(field.type)},`), `}${suffix}`];
}

function defaultValue(type) {
	switch (type.kind) {
		case "Boolean":
			return "false";
		case "String":
			return '""';
		case "Enum":
			return luaString(type.values[0]);
		case "Array":
		case "Map":
			return "{}";
		case "Optional":
			return undefined;
		default:
			return "0";
	}
}

export function defaultStateLines(depth, fields) {
	const indent = "\t".repeat(depth);
	const entries = fields.flatMap((field) => {
		const value = defaultValue(field.type);
		return value === undefined ? [] : [`${field.name} = ${value}`];
	});
	if (entries.length === 0) return [`${indent}return {}`];
	return [`${indent}return {`, ...entries.map((entry) => `${indent}\t${entry},`), `${indent}}`];
}
