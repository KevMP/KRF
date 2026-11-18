import assert from "node:assert/strict";
import test from "node:test";

import { defaultStateLines, parseEvent, parseFields, renderType, structLines, structTypeLines } from "../src/generate/schema.js";

test("renders every schema type as KRF.Schema calls", () => {
	const fields = parseFields([
		"Flag:Boolean",
		"Amount:U16",
		"Label:String(32)",
		"Element:Enum(Fire|Ice)",
		"Target:Optional(U32)",
		"Position:Array(F32,3)",
		"Scores:Map(String(8),Optional(I32),4)",
	]);
	assert.deepEqual(
		fields.map((field) => renderType(field.type)),
		[
			"KRF.Schema.Boolean",
			"KRF.Schema.U16",
			"KRF.Schema.String(32)",
			'KRF.Schema.Enum({ "Fire", "Ice" })',
			"KRF.Schema.Optional(KRF.Schema.U32)",
			"KRF.Schema.Array(KRF.Schema.F32, 3)",
			"KRF.Schema.Map(KRF.Schema.String(8), KRF.Schema.Optional(KRF.Schema.I32), 4)",
		],
	);
});

test("writes an empty struct inline and one field per line otherwise", () => {
	assert.deepEqual(structLines(1, "payload = ", []), ["\tpayload = KRF.Schema.Struct({}),"]);
	assert.deepEqual(structLines(1, "state = ", parseFields(["Count:U8", "Active:Boolean"])), [
		"\tstate = KRF.Schema.Struct({",
		"\t\tCount = KRF.Schema.U8,",
		"\t\tActive = KRF.Schema.Boolean,",
		"\t}),",
	]);
});

test("writes each field's exact Luau type for the payload a producer returns", () => {
	const fields = parseFields([
		"Flag:Boolean",
		"Amount:U16",
		"Label:String(32)",
		"Element:Enum(Fire|Ice)",
		"Mode:Optional(Enum(Fast|Slow))",
		"Only:Optional(Enum(Solo))",
		"Target:Optional(U32)",
		"Grid:Array(Array(F32,3),8)",
		"Scores:Map(String(8),Optional(I32),4)",
	]);
	assert.deepEqual(structTypeLines("f = function(): ", fields), [
		"f = function(): {",
		"\tFlag: boolean,",
		"\tAmount: number,",
		"\tLabel: string,",
		'\tElement: "Fire" | "Ice",',
		'\tMode: ("Fast" | "Slow")?,',
		'\tOnly: "Solo"?,',
		"\tTarget: number?,",
		"\tGrid: { { number } },",
		"\tScores: { [string]: number? },",
		"}",
	]);
});

test("a snapshot starts every required field at its zero value and leaves optional fields out", () => {
	assert.deepEqual(defaultStateLines(2, []), ["\t\treturn {}"]);
	assert.deepEqual(defaultStateLines(2, parseFields(["Count:U8", "Active:Boolean", "Label:String(4)", "Element:Enum(Fire|Ice)", "Hits:Array(U8,2)", "Note:Optional(String(4))"])), [
		"\t\treturn {",
		"\t\t\tCount = 0,",
		"\t\t\tActive = false,",
		'\t\t\tLabel = "",',
		'\t\t\tElement = "Fire",',
		"\t\t\tHits = {},",
		"\t\t}",
	]);
});

test("parses events with and without payload fields and rejects malformed types", () => {
	assert.deepEqual(parseEvent("Reset"), { id: "Reset", fields: [] });
	assert.deepEqual(parseEvent("Hit(Damage:U16, Critical:Boolean)"), {
		id: "Hit",
		fields: [
			{ name: "Damage", type: { kind: "U16" } },
			{ name: "Critical", type: { kind: "Boolean" } },
		],
	});

	for (const [spec, message] of [
		["Amount", /must be Name:Type/],
		["Amount:Number", /is not a schema type/],
		["Label:String(0)", /String maxBytes must be a whole number/],
		["Element:Enum(Fire|Fire)", /lists a value twice/],
		["Element:Enum(fire-ball)", /Enum values must be names/],
		["Map:Map(U8,U8)", /Map takes a key type, a value type and a maximum size/],
	]) {
		assert.throws(() => parseFields([spec]), { name: "SyntaxError", message }, spec);
	}
});
