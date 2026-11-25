export class JsonNumber {
	constructor(raw) {
		this.raw = raw;
	}
}

const WHITESPACE = /[ \t\r\n]*/y;
const STRING = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
const LITERAL = /true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;

export function parseJson(text) {
	let index = 0;

	const fail = (message) => {
		throw new SyntaxError(`${message} at position ${index}`);
	};

	const match = (pattern) => {
		pattern.lastIndex = index;
		const found = pattern.exec(text);
		if (found !== null) index = pattern.lastIndex;
		return found?.[0];
	};

	const skip = () => match(WHITESPACE);

	const expect = (character) => {
		skip();
		if (text[index] !== character) fail(`Expected '${character}'`);
		index += 1;
	};

	const string = () => {
		const token = match(STRING);
		if (token === undefined) fail("Expected a string");
		return JSON.parse(token);
	};

	function value() {
		skip();
		const character = text[index];
		if (character === "{") {
			index += 1;
			const object = {};
			skip();
			if (text[index] === "}") {
				index += 1;
				return object;
			}
			for (;;) {
				skip();
				const key = string();
				expect(":");
				Object.defineProperty(object, key, { value: value(), enumerable: true, writable: true, configurable: true });
				skip();
				const next = text[index++];
				if (next === "}") return object;
				if (next !== ",") fail("Expected ',' or '}'");
			}
		}
		if (character === "[") {
			index += 1;
			const array = [];
			skip();
			if (text[index] === "]") {
				index += 1;
				return array;
			}
			for (;;) {
				array.push(value());
				skip();
				const next = text[index++];
				if (next === "]") return array;
				if (next !== ",") fail("Expected ',' or ']'");
			}
		}
		if (character === '"') return string();
		const literal = match(LITERAL);
		if (literal === undefined) fail("Unexpected token");
		if (literal === "true") return true;
		if (literal === "false") return false;
		if (literal === "null") return null;
		return new JsonNumber(literal);
	}

	const result = value();
	skip();
	if (index !== text.length) fail("Unexpected content");
	return result;
}

export function stringifyJson(value, indent = "") {
	if (value instanceof JsonNumber) return value.raw;
	if (value === null || typeof value !== "object") return JSON.stringify(value);

	const inner = `${indent}  `;
	if (Array.isArray(value)) {
		if (value.length === 0) return "[]";
		return `[\n${value.map((item) => `${inner}${stringifyJson(item, inner)}`).join(",\n")}\n${indent}]`;
	}

	const entries = Object.entries(value);
	if (entries.length === 0) return "{}";
	return `{\n${entries.map(([key, item]) => `${inner}${JSON.stringify(key)}: ${stringifyJson(item, inner)}`).join(",\n")}\n${indent}}`;
}
