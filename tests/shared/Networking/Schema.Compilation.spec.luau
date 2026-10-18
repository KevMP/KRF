--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler: SharedNetworkingTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.SchemaTestUtils)

type SchemaDefinition = SharedNetworkingTypes.SchemaDefinition
type CompiledSchema = SharedNetworkingTypes.CompiledSchema

local MAX_SAFE_INTEGER: number = 9007199254740991

local function expectRejected(definition: any, expectedReason: string): ()
	local compiled: CompiledSchema?, reason: string? = Compiler.Compile(definition)
	expect(compiled).toBeNil()
	expect(reason).toBe(expectedReason)
end

local function expectFiniteBound(compiled: CompiledSchema): ()
	local maximum: number = compiled.maxEncodedBytes
	expect(maximum == maximum).toBe(true)
	expect(maximum < math.huge).toBe(true)
	expect(maximum <= MAX_SAFE_INTEGER).toBe(true)
	expect(maximum >= 0).toBe(true)
	expect(maximum % 1).toBe(0)
end

it("rejects missing, non-table, and unsupported arbitrary-table schema definitions", function()
	expectRejected(nil, "SchemaDefinitionMissing")
	expectRejected("U8", "SchemaDefinitionMustBeTable")
	expectRejected(true, "SchemaDefinitionMustBeTable")
	expectRejected({}, "SchemaKindInvalid")
	expectRejected({ kind = "Any" }, "SchemaKindInvalid")
	expectRejected({ kind = "Table" }, "SchemaKindInvalid")
	expectRejected({ kind = "Dictionary" }, "SchemaKindInvalid")
	expectRejected({ kind = "Number" }, "SchemaKindInvalid")
end)

type InvalidEnumCase = { name: string, definition: any, reason: string }

local invalidEnums: { InvalidEnumCase } = {
	{ name = "missing membership", definition = { kind = "Enum" }, reason = "SchemaEnumValuesMustBeArray" },
	{
		name = "non-table membership",
		definition = { kind = "Enum", values = "Idle" },
		reason = "SchemaEnumValuesMustBeArray",
	},
	{
		name = "empty membership",
		definition = { kind = "Enum", values = {} },
		reason = "SchemaEnumValuesCannotBeEmpty",
	},
	{
		name = "duplicate membership",
		definition = { kind = "Enum", values = { "Idle", "Idle" } },
		reason = "SchemaEnumValueDuplicate",
	},
	{ name = "empty member", definition = { kind = "Enum", values = { "" } }, reason = "SchemaEnumValueInvalid" },
	{
		name = "non-string member",
		definition = { kind = "Enum", values = { "Idle", 1 } },
		reason = "SchemaEnumValueInvalid",
	},
	{
		name = "sparse membership",
		definition = { kind = "Enum", values = { [1] = "Idle", [3] = "Block" } },
		reason = "SchemaEnumValuesMustBeArray",
	},
	{
		name = "dictionary membership",
		definition = { kind = "Enum", values = { Idle = "Idle" } },
		reason = "SchemaEnumValuesMustBeArray",
	},
}

for _, enumCase: InvalidEnumCase in invalidEnums do
	it("Enum compilation rejects " .. enumCase.name .. " with a stable reason", function()
		expectRejected(enumCase.definition, enumCase.reason)
	end)
end

it("normalizes Enum code ordering independently of declaration order", function()
	local first: CompiledSchema = TestUtils.compile(Schema.Enum({ "Stunned", "Idle", "Blocking" }))
	local second: CompiledSchema = TestUtils.compile(Schema.Enum({ "Blocking", "Stunned", "Idle" }))
	assert(first.kind == "Enum" and second.kind == "Enum", "Expected compiled Enum schemas")
	expect(first.values).toEqual({ "Blocking", "Idle", "Stunned" })
	expect(second).toEqual(first)
	TestUtils.expectValid(first, "Idle")
	TestUtils.expectValid(second, "Idle")
end)

it("normalizes Struct fields independently of insertion order without losing nested schemas", function()
	local firstFields: { [string]: SchemaDefinition } = {}
	firstFields.zeta = Schema.Struct({ remaining = Schema.F32 })
	firstFields.alpha = Schema.Boolean
	firstFields.middle = Schema.U16

	local secondFields: { [string]: SchemaDefinition } = {}
	secondFields.middle = Schema.U16
	secondFields.alpha = Schema.Boolean
	secondFields.zeta = Schema.Struct({ remaining = Schema.F32 })

	local first: CompiledSchema = TestUtils.compile(Schema.Struct(firstFields))
	local second: CompiledSchema = TestUtils.compile(Schema.Struct(secondFields))
	assert(first.kind == "Struct" and second.kind == "Struct", "Expected compiled Struct schemas")
	expect(first.fields[1].name).toBe("alpha")
	expect(first.fields[2].name).toBe("middle")
	expect(first.fields[3].name).toBe("zeta")
	expect(first.fields[3].schema.kind).toBe("Struct")
	expect(second).toEqual(first)
end)

it("rejects invalid Struct field tables, names, and nested schema definitions", function()
	expectRejected({ kind = "Struct" }, "SchemaStructFieldsMustBeTable")
	expectRejected({ kind = "Struct", fields = false }, "SchemaStructFieldsMustBeTable")
	expectRejected({ kind = "Struct", fields = { [""] = Schema.U8 } }, "SchemaStructFieldNameInvalid")
	expectRejected({ kind = "Struct", fields = { [1] = Schema.U8 } }, "SchemaStructFieldNameInvalid")
	expectRejected({ kind = "Struct", fields = { bad = {} } }, "SchemaKindInvalid")
	expectRejected({ kind = "Struct", fields = { bad = "U8" } }, "SchemaDefinitionMustBeTable")
end)

it("rejects absent or malformed children of Optional, Array, and Map schemas", function()
	expectRejected({ kind = "Optional" }, "SchemaDefinitionMissing")
	expectRejected({ kind = "Optional", inner = {} }, "SchemaKindInvalid")
	expectRejected({ kind = "Array", maxLength = 2 }, "SchemaDefinitionMissing")
	expectRejected({ kind = "Array", element = {}, maxLength = 2 }, "SchemaKindInvalid")
	expectRejected({ kind = "Map", value = Schema.U8, maxEntries = 2 }, "SchemaDefinitionMissing")
	expectRejected({ kind = "Map", key = Schema.U8, maxEntries = 2 }, "SchemaDefinitionMissing")
	expectRejected({ kind = "Map", key = Schema.U8, value = {}, maxEntries = 2 }, "SchemaKindInvalid")
end)

it("fully validates structural bounds even when definitions bypass friendly constructors", function()
	local invalidBounds: { any } = { 0, -1, 1.5, "2", false, 0 / 0, math.huge, -math.huge }

	for _, bound: any in invalidBounds do
		expectRejected({ kind = "String", maxBytes = bound }, "SchemaStringMaxBytesInvalid")
		expectRejected({ kind = "Array", element = Schema.U8, maxLength = bound }, "SchemaArrayMaxLengthInvalid")

		expectRejected(
			{ kind = "Map", key = Schema.U8, value = Schema.U8, maxEntries = bound },
			"SchemaMapMaxEntriesInvalid"
		)
	end

	expectRejected({ kind = "String" }, "SchemaStringMaxBytesInvalid")
	expectRejected({ kind = "Array", element = Schema.U8 }, "SchemaArrayMaxLengthInvalid")
	expectRejected({ kind = "Map", key = Schema.U8, value = Schema.U8 }, "SchemaMapMaxEntriesInvalid")
end)

it("rejects complex and Optional Map keys while allowing deterministic string, enum, and integer keys", function()
	local unsupportedKeys: { SchemaDefinition } = {
		Schema.Struct({ id = Schema.U8 }),
		Schema.Array(Schema.U8, 2),
		Schema.Map(Schema.U8, Schema.U8, 2),
		Schema.Optional(Schema.U8),
	}

	for _, key: SchemaDefinition in unsupportedKeys do
		expectRejected({ kind = "Map", key = key, value = Schema.U8, maxEntries = 2 }, "SchemaMapKeyUnsupported")
	end

	local supportedKeys: { SchemaDefinition } = {
		Schema.String(8),
		Schema.Enum({ "Idle" }),
		Schema.U8,
		Schema.U16,
		Schema.U32,
		Schema.I8,
		Schema.I16,
		Schema.I32,
	}

	for _, key: SchemaDefinition in supportedKeys do
		local compiled: CompiledSchema = TestUtils.compile(Schema.Map(key, Schema.Boolean, 2))
		expectFiniteBound(compiled)
	end
end)

local unsupportedScalarKeys: { SchemaDefinition } = { Schema.Boolean, Schema.F32, Schema.F64 }

for _, key: SchemaDefinition in unsupportedScalarKeys do
	it("rejects " .. key.kind .. " Map keys with the stable unsupported-key reason", function()
		expectRejected({ kind = "Map", key = key, value = Schema.U8, maxEntries = 2 }, "SchemaMapKeyUnsupported")
	end)
end

it("rejects direct and indirect recursive definitions without hanging or publishing a partial result", function()
	local recursive: any = { kind = "Optional" }
	recursive.inner = recursive
	expectRejected(recursive, "SchemaRecursiveDefinition")
	local parent: any = { kind = "Struct", fields = {} }
	local child: any = { kind = "Array", element = parent, maxLength = 2 }

	parent.fields.child = child
	expectRejected(parent, "SchemaRecursiveDefinition")
end)

it("accepts shared child definitions without mistaking reuse for recursion", function()
	local sharedChild: SchemaDefinition = Schema.Struct({ value = Schema.U8 })
	local compiled: CompiledSchema = TestUtils.compile(Schema.Struct({ first = sharedChild, second = sharedChild }))
	TestUtils.expectValid(compiled, { first = { value = 1 }, second = { value = 2 } })
	expectFiniteBound(compiled)
end)

it("owns compiled Enum and Struct metadata without freezing or retaining mutable source tables", function()
	local sourceValues: { string } = { "Idle", "Blocking" }
	local sourceEnum: any = { kind = "Enum", values = sourceValues }
	local sourceFields: any = { mode = sourceEnum, guard = { kind = "U8" } }
	local source: any = { kind = "Struct", fields = sourceFields }
	local compiled: CompiledSchema = TestUtils.compile(source)

	sourceValues[1] = "Flying"
	sourceEnum.kind = "Boolean"
	sourceFields.guard.kind = "Boolean"
	sourceFields.extra = Schema.F64
	source.kind = "Map"
	TestUtils.expectValid(compiled, { mode = "Idle", guard = 0 })
	TestUtils.expectInvalid(compiled, { mode = "Flying", guard = 0 }, "SchemaEnumValueInvalid")
	TestUtils.expectInvalid(compiled, { mode = "Idle", guard = false }, "SchemaValueTypeInvalid")
	expect(table.isfrozen(source)).toBe(false)
	expect(table.isfrozen(sourceFields)).toBe(false)
	expect(table.isfrozen(sourceValues)).toBe(false)
	assert(compiled.kind == "Struct", "Expected compiled Struct metadata")
	expect(table.isfrozen(compiled)).toBe(true)
	expect(table.isfrozen(compiled.fields)).toBe(true)

	for _, field: SharedNetworkingTypes.CompiledField in compiled.fields do
		expect(table.isfrozen(field)).toBe(true)
		expect(table.isfrozen(field.schema)).toBe(true)

		if field.schema.kind == "Enum" then
			expect(table.isfrozen(field.schema.values)).toBe(true)
		end
	end
end)

it("owns and freezes nested collection contracts including all child schemas", function()
	local source: any = {
		kind = "Map",
		key = { kind = "String", maxBytes = 8 },
		maxEntries = 2,
		value = { kind = "Array", maxLength = 3, element = { kind = "Optional", inner = { kind = "U8" } } },
	}

	local compiled: CompiledSchema = TestUtils.compile(source)

	source.key.maxBytes = 100
	source.maxEntries = 100
	source.value.maxLength = 100
	source.value.element.inner.kind = "Boolean"
	assert(compiled.kind == "Map", "Expected compiled Map metadata")
	expect(compiled.maxEntries).toBe(2)
	assert(compiled.key.kind == "String" and compiled.value.kind == "Array", "Expected String keys and Array values")
	expect(compiled.key.maxBytes).toBe(8)
	expect(compiled.value.maxLength).toBe(3)
	assert(compiled.value.element.kind == "Optional", "Expected Optional array elements")
	expect(compiled.value.element.inner.kind).toBe("U8")
	expect(table.isfrozen(compiled)).toBe(true)
	expect(table.isfrozen(compiled.key)).toBe(true)
	expect(table.isfrozen(compiled.value)).toBe(true)
	expect(table.isfrozen(compiled.value.element)).toBe(true)
	expect(table.isfrozen(compiled.value.element.inner)).toBe(true)
end)

it("compiles frozen source descriptors without attempting to normalize them in place", function()
	local source: any = table.freeze({ kind = "Enum", values = table.freeze({ "Stunned", "Idle" }) })
	local compiled: CompiledSchema = TestUtils.compile(source)
	assert(compiled.kind == "Enum", "Expected compiled Enum metadata")
	expect(compiled.values).toEqual({ "Idle", "Stunned" })
	expect(source.values).toEqual({ "Stunned", "Idle" })
end)

it("derives fixed numeric widths and a finite Boolean maximum", function()
	local definitions: { SchemaDefinition } = {
		Schema.U8,
		Schema.U16,
		Schema.U32,
		Schema.I8,
		Schema.I16,
		Schema.I32,
		Schema.F32,
		Schema.F64,
	}

	local widths: { number } = { 1, 2, 4, 1, 2, 4, 4, 8 }

	for index: number, definition: SchemaDefinition in definitions do
		local compiled: CompiledSchema = TestUtils.compile(definition)
		expectFiniteBound(compiled)
		expect(compiled.maxEncodedBytes).toBe(widths[index])
	end

	expectFiniteBound(TestUtils.compile(Schema.Boolean))
end)

it("derives finite String and Enum maxima without exposing a length-prefix or ordinal byte layout", function()
	local boundedString: CompiledSchema = TestUtils.compile(Schema.String(64))
	expectFiniteBound(boundedString)
	expect(boundedString.maxEncodedBytes >= 64).toBe(true)
	expectFiniteBound(TestUtils.compile(Schema.Enum({ "Idle", "Blocking" })))
end)

it("derives Struct, Optional, Array, and Map maxima recursively", function()
	local child: CompiledSchema = TestUtils.compile(Schema.U16)
	local record: CompiledSchema = TestUtils.compile(Schema.Struct({ first = Schema.U16, second = Schema.U16 }))
	local optional: CompiledSchema = TestUtils.compile(Schema.Optional(Schema.U16))
	local array: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U16, 32))
	local map: CompiledSchema = TestUtils.compile(Schema.Map(Schema.U16, Schema.F32, 16))

	for _, compiled: CompiledSchema in { record, optional, array, map } do
		expectFiniteBound(compiled)
	end

	expect(record.maxEncodedBytes >= 2 * child.maxEncodedBytes).toBe(true)
	expect(optional.maxEncodedBytes > child.maxEncodedBytes).toBe(true)
	expect(array.maxEncodedBytes >= 32 * child.maxEncodedBytes).toBe(true)
	expect(map.maxEncodedBytes >= 16 * (2 + 4)).toBe(true)
end)

it("increasing collection bounds cannot reduce the maximum encoded size", function()
	local smallString: CompiledSchema = TestUtils.compile(Schema.String(4))
	local largeString: CompiledSchema = TestUtils.compile(Schema.String(64))
	local smallArray: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U16, 2))
	local largeArray: CompiledSchema = TestUtils.compile(Schema.Array(Schema.U16, 32))
	local smallMap: CompiledSchema = TestUtils.compile(Schema.Map(Schema.U8, Schema.U16, 2))
	local largeMap: CompiledSchema = TestUtils.compile(Schema.Map(Schema.U8, Schema.U16, 32))
	expect(largeString.maxEncodedBytes > smallString.maxEncodedBytes).toBe(true)
	expect(largeArray.maxEncodedBytes > smallArray.maxEncodedBytes).toBe(true)
	expect(largeMap.maxEncodedBytes > smallMap.maxEncodedBytes).toBe(true)
end)

it("deeply nested bounded schemas retain finite introspectable maxima", function()
	local definition: SchemaDefinition = Schema.U8

	for _ = 1, 32 do
		definition = Schema.Struct({ child = Schema.Optional(Schema.Array(definition, 1)) })
	end

	local compiled: CompiledSchema = TestUtils.compile(definition)
	expectFiniteBound(compiled)
	expect(compiled.kind).toBe("Struct")
end)

it("rejects nested bounds whose maximum encoded size cannot remain finite", function()
	local definition: any = { kind = "U8" }

	-- Keep structural depth modest so a private depth guard cannot mask size rejection.
	for _ = 1, 20 do
		definition = { kind = "Array", element = definition, maxLength = 2 ^ 52 }
	end

	expectRejected(definition, "SchemaEncodedSizeInvalid")
end)

it("rejects finite Array multiplication that exceeds exact safe integer byte accounting", function()
	-- The cardinality itself is a positive safe integer; eight bytes per element
	-- already exceed the safe byte maximum before any private collection overhead.
	local definition: SchemaDefinition = { kind = "Array", element = Schema.F64, maxLength = 2 ^ 50 }
	expectRejected(definition, "SchemaEncodedSizeInvalid")
end)

it("rejects finite Map multiplication that exceeds exact safe integer byte accounting", function()
	local definition: SchemaDefinition = {
		kind = "Map",
		key = Schema.U32,
		value = Schema.F64,
		maxEntries = 2 ^ 50,
	}

	expectRejected(definition, "SchemaEncodedSizeInvalid")
end)

it("rejects Struct addition of individually bounded children beyond the safe integer byte maximum", function()
	-- Even with no collection overhead, the mathematical sum is 2^53 + 1.
	-- Luau rounds that sum, so checking finite/integral arithmetic is insufficient.
	local child: SchemaDefinition = { kind = "Array", element = Schema.U8, maxLength = 2 ^ 52 }
	local fields: { [string]: SchemaDefinition } = { first = child, second = child, last = Schema.U8 }
	local definition: SchemaDefinition = { kind = "Struct", fields = fields }
	expectRejected(definition, "SchemaEncodedSizeInvalid")
end)

it("rejects 10000 non-recursive Optional levels cleanly without exposing the private depth limit", function()
	-- Build raw descriptors iteratively to exercise compiler admission rather than
	-- constructor recursion or the test fixture's own call stack.
	local definition: SchemaDefinition = { kind = "U8" }

	for _ = 1, 10000 do
		definition = { kind = "Optional", inner = definition }
	end

	local compiled: CompiledSchema? = nil
	local reason: string? = nil

	local completed: boolean = pcall(function()
		compiled, reason = Compiler.Compile(definition)
	end)

	expect(completed).toBe(true)
	expect(compiled).toBeNil()
	expect(reason).toBe("SchemaDepthExceeded")
	TestUtils.expectValid(TestUtils.compile(Schema.U8), 255)
end)

it("rejects excessive mixed structural depth even when every collection has a bound of one", function()
	local definition: SchemaDefinition = { kind = "U8" }

	for _ = 1, 2500 do
		local optionalChild: SchemaDefinition = { kind = "Optional", inner = definition }
		local arrayChild: SchemaDefinition = { kind = "Array", element = optionalChild, maxLength = 1 }
		local mapChild: SchemaDefinition = { kind = "Map", key = Schema.U8, value = arrayChild, maxEntries = 1 }
		local fields: { [string]: SchemaDefinition } = { child = mapChild }
		definition = { kind = "Struct", fields = fields }
	end

	local compiled: CompiledSchema? = nil
	local reason: string? = nil

	local completed: boolean = pcall(function()
		compiled, reason = Compiler.Compile(definition)
	end)

	expect(completed).toBe(true)
	expect(compiled).toBeNil()
	expect(reason).toBe("SchemaDepthExceeded")
end)

it("a rejected schema does not poison subsequent compilation or mutate its source", function()
	local source: any = { kind = "Struct", fields = { valid = { kind = "U8" }, invalid = {} } }
	expectRejected(source, "SchemaKindInvalid")
	expect(source).toEqual({ kind = "Struct", fields = { valid = { kind = "U8" }, invalid = {} } })
	expect(table.isfrozen(source)).toBe(false)
	expect(table.isfrozen(source.fields)).toBe(false)
	TestUtils.expectValid(TestUtils.compile(Schema.U8), 255)
end)
