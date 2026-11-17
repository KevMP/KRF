const KEYWORDS = new Set([
	"and",
	"break",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
]);

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;
const COLUMN_WIDTH = 120;
const INDENT_WIDTH = 4;

export function isIdentifier(value) {
	return IDENTIFIER.test(value) && !KEYWORDS.has(value);
}

export function luaString(value) {
	return JSON.stringify(value);
}

export function luaKey(key) {
	return isIdentifier(key) ? key : `[${luaString(key)}]`;
}

export function luaNumber(value) {
	return String(value);
}

function width(line) {
	return line.replace(/\t/g, " ".repeat(INDENT_WIDTH)).length;
}

export function tableField(depth, key, items, options = {}) {
	const indent = "\t".repeat(depth);
	const single = `${indent}${key} = { ${items.join(", ")} },`;
	if (!options.expand && width(single) <= COLUMN_WIDTH) return [single];
	return [`${indent}${key} = {`, ...items.map((item) => `${indent}\t${item},`), `${indent}},`];
}

export function splitLines(source) {
	const eol = source.includes("\r\n") ? "\r\n" : "\n";
	return { lines: source.split(/\r?\n/), eol };
}
