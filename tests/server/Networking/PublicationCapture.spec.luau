--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler: SchemaTypes.SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Codecs: SchemaTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Capture: PublicationTypes.CaptureModule = require(KRF.server.Networking.PublicationCapture)

local function compile(definition: SchemaTypes.SchemaDefinition): PublicationTypes.CapturePlan
	local schema: SchemaTypes.CompiledSchema?, reason: string? = Compiler.Compile(definition)
	expect(reason).toBeNil()
	assert(schema ~= nil, "Expected compiled capture schema")
	return Capture.Compile(schema)
end

local function capture(
	plan: PublicationTypes.CapturePlan,
	value: any,
	previous: PublicationTypes.CaptureResult?
): PublicationTypes.CaptureResult
	local result: PublicationTypes.CaptureResult?, reason: string? = plan:Capture(value, previous)
	expect(reason).toBeNil()
	assert(result ~= nil, "Expected schema-owned capture")
	return result
end

type ScalarCase = { name: string, schema: SchemaTypes.SchemaDefinition, before: any, after: any, bytes: number }
local scalarCases: { ScalarCase } = {
	{ name = "Boolean", schema = Schema.Boolean, before = false, after = true, bytes = 1 },
	{ name = "U8", schema = Schema.U8, before = 255, after = 0, bytes = 1 },
	{ name = "U16", schema = Schema.U16, before = 65535, after = 0, bytes = 2 },
	{ name = "U32", schema = Schema.U32, before = 4294967295, after = 0, bytes = 4 },
	{ name = "I8", schema = Schema.I8, before = -128, after = 127, bytes = 1 },
	{ name = "I16", schema = Schema.I16, before = -32768, after = 32767, bytes = 2 },
	{ name = "I32", schema = Schema.I32, before = -2147483648, after = 2147483647, bytes = 4 },
	{ name = "F32", schema = Schema.F32, before = 1.5, after = 1.75, bytes = 4 },
	{ name = "F64", schema = Schema.F64, before = 1.5, after = 1.50000000001, bytes = 8 },
}

for _, case: ScalarCase in scalarCases do
	it(case.name .. " captures unchanged truth without a patch and changed truth as an absolute replacement", function()
		local plan: PublicationTypes.CapturePlan = compile(case.schema)
		local initial: PublicationTypes.CaptureResult = capture(plan, case.before, nil)
		expect(initial.value).toBe(case.before)
		expect(initial.encodedSizeBytes).toBe(case.bytes)
		local unchanged: PublicationTypes.CaptureResult = capture(plan, case.before, initial)
		expect(unchanged.patch).toBeNil()
		local changed: PublicationTypes.CaptureResult = capture(plan, case.after, unchanged)
		expect(changed.value).toBe(case.after)
		expect(changed.patch).toEqual({ kind = "Replace", value = case.after })
	end)
end

it("compares Enum and String values exactly without fuzzy or case-insensitive matching", function()
	for _, definition: SchemaTypes.SchemaDefinition in { Schema.Enum({ "Ready", "Spent" }), Schema.String(8) } do
		local plan: PublicationTypes.CapturePlan = compile(definition)
		local initial: PublicationTypes.CaptureResult = capture(plan, "Ready", nil)
		expect(capture(plan, "Ready", initial).patch).toBeNil()
		expect(capture(plan, "Spent", initial).patch).toEqual({ kind = "Replace", value = "Spent" })
	end
end)

it("emits only changed Struct fields and omits unchanged nested subtrees", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.Struct({
		current = Schema.U8,
		settings = Schema.Struct({ active = Schema.Boolean, maximum = Schema.U8 }),
	}))
	local initial: PublicationTypes.CaptureResult =
		capture(plan, { current = 80, settings = { active = false, maximum = 100 } }, nil)
	local changed: PublicationTypes.CaptureResult =
		capture(plan, { current = 54, settings = { active = true, maximum = 100 } }, initial)
	expect(changed.patch).toEqual({
		kind = "Struct",
		fields = {
			current = { kind = "Replace", value = 54 },
			settings = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
		},
	})
	expect(changed.value).toEqual({ current = 54, settings = { active = true, maximum = 100 } })
	expect(initial.value).toEqual({ current = 80, settings = { active = false, maximum = 100 } })
end)

it("represents Optional absent to present and present to absent with explicit absolute replacements", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.Optional(Schema.U8))
	local absent: PublicationTypes.CaptureResult = capture(plan, nil, nil)
	expect(absent.value).toBeNil()
	expect(capture(plan, nil, absent).patch).toBeNil()
	local present: PublicationTypes.CaptureResult = capture(plan, 0, absent)
	expect(present.patch).toEqual({ kind = "Replace", value = 0 })
	expect(capture(plan, nil, present).patch).toEqual({ kind = "Replace" })
end)

it("preserves an explicit Optional removal inside a Struct instead of silently omitting it", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.Struct({ target = Schema.Optional(Schema.String(8)) }))
	local initial: PublicationTypes.CaptureResult = capture(plan, { target = "Enemy" }, nil)
	expect(capture(plan, {}, initial).patch).toEqual({ kind = "Struct", fields = { target = { kind = "Replace" } } })
end)

it("emits Map additions, removals and whole-entry updates while omitting unchanged entries", function()
	local plan: PublicationTypes.CapturePlan =
		compile(Schema.Map(Schema.String(8), Schema.Struct({ stacks = Schema.U8, active = Schema.Boolean }), 4))
	local initial: PublicationTypes.CaptureResult = capture(plan, {
		Kept = { stacks = 1, active = true },
		Gone = { stacks = 2, active = true },
		Changed = { stacks = 3, active = true },
	}, nil)
	local changed: PublicationTypes.CaptureResult = capture(plan, {
		Kept = { stacks = 1, active = true },
		Added = { stacks = 4, active = false },
		Changed = { stacks = 5, active = true },
	}, initial)
	expect(changed.patch).toEqual({
		kind = "Map",
		entries = {
			Added = { stacks = 4, active = false },
			Changed = { stacks = 5, active = true },
		},
		removed = { "Gone" },
	})
	expect(changed.value).toEqual({
		Kept = { stacks = 1, active = true },
		Added = { stacks = 4, active = false },
		Changed = { stacks = 5, active = true },
	})
	expect(capture(plan, changed.value, changed).patch).toBeNil()
end)

it("distinguishes a false Map entry from an absent key", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.Map(Schema.U8, Schema.Boolean, 2))
	local initial: PublicationTypes.CaptureResult = capture(plan, {}, nil)
	local added: PublicationTypes.CaptureResult = capture(plan, { [0] = false }, initial)
	expect(added.patch).toEqual({ kind = "Map", entries = { [0] = false }, removed = {} })
	expect(capture(plan, {}, added).patch).toEqual({ kind = "Map", entries = {}, removed = { 0 } })
end)

it("replaces a changed Array as one ordered value including reordering and clearing", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.Array(Schema.U8, 3))
	local initial: PublicationTypes.CaptureResult = capture(plan, { 1, 2 }, nil)
	expect(capture(plan, { 1, 2 }, initial).patch).toBeNil()
	expect(capture(plan, { 2, 1 }, initial).patch).toEqual({ kind = "Replace", value = { 2, 1 } })
	expect(capture(plan, {}, initial).patch).toEqual({ kind = "Replace", value = {} })
end)

it("owns nested snapshot and patch data when the same mutable source table is reused", function()
	local source: any = { nested = { count = 1 }, values = { 10, 20 } }
	local plan: PublicationTypes.CapturePlan =
		compile(Schema.Struct({ nested = Schema.Struct({ count = Schema.U8 }), values = Schema.Array(Schema.U8, 2) }))
	local initial: PublicationTypes.CaptureResult = capture(plan, source, nil)
	source.nested.count = 2
	source.values[1] = 30
	local changed: PublicationTypes.CaptureResult = capture(plan, source, initial)
	source.nested.count = 3
	source.values[1] = 40
	expect(initial.value).toEqual({ nested = { count = 1 }, values = { 10, 20 } })
	expect(changed.value).toEqual({ nested = { count = 2 }, values = { 30, 20 } })
	expect(changed.patch).toEqual({
		kind = "Struct",
		fields = {
			nested = { kind = "Struct", fields = { count = { kind = "Replace", value = 2 } } },
			values = { kind = "Replace", value = { 30, 20 } },
		},
	})
end)

type InvalidCase = { name: string, schema: SchemaTypes.SchemaDefinition, initial: any, invalid: any, reason: string }
local invalidCases: { InvalidCase } = {
	{
		name = "wrong primitive type",
		schema = Schema.U8,
		initial = 1,
		invalid = false,
		reason = "SchemaValueTypeInvalid",
	},
	{ name = "integer overflow", schema = Schema.U8, initial = 1, invalid = 256, reason = "SchemaIntegerOutOfRange" },
	{
		name = "non-finite float",
		schema = Schema.F64,
		initial = 1,
		invalid = math.huge,
		reason = "SchemaNumberMustBeFinite",
	},
	{
		name = "undeclared Struct field",
		schema = Schema.Struct({ active = Schema.Boolean }),
		initial = { active = false },
		invalid = { active = true, extra = true },
		reason = "SchemaStructFieldUndeclared",
	},
	{
		name = "String byte overflow",
		schema = Schema.String(2),
		initial = "ok",
		invalid = "long",
		reason = "SchemaStringTooLong",
	},
	{
		name = "Array length overflow",
		schema = Schema.Array(Schema.U8, 1),
		initial = { 1 },
		invalid = { 1, 2 },
		reason = "SchemaArrayTooLong",
	},
	{
		name = "Map entry overflow",
		schema = Schema.Map(Schema.U8, Schema.U8, 1),
		initial = { [1] = 1 },
		invalid = { [1] = 1, [2] = 2 },
		reason = "SchemaMapTooLarge",
	},
}
for _, case: InvalidCase in invalidCases do
	it("rejects " .. case.name .. " without altering the previous canonical capture", function()
		local plan: PublicationTypes.CapturePlan = compile(case.schema)
		local initial: PublicationTypes.CaptureResult = capture(plan, case.initial, nil)
		local rejected: PublicationTypes.CaptureResult?, reason: string? = plan:Capture(case.invalid, initial)
		expect(rejected).toBeNil()
		expect(reason).toBe(case.reason)
		expect(initial.value).toEqual(case.initial)
		expect(capture(plan, case.initial, initial).patch).toBeNil()
	end)
end

it("uses exact represented F32 values without a gameplay epsilon", function()
	local plan: PublicationTypes.CapturePlan = compile(Schema.F32)
	local initial: PublicationTypes.CaptureResult = capture(plan, 1, nil)
	-- Both inputs encode to the same F32; a difference of one ULP must survive.
	expect(capture(plan, 1 + 2 ^ -25, initial).patch).toBeNil()
	expect(capture(plan, 1 + 2 ^ -23, initial).patch).toEqual({ kind = "Replace", value = 1 + 2 ^ -23 })
end)

it("accounts for variable-sized captured values using N2 codec bytes", function()
	local definition: SchemaTypes.SchemaDefinition =
		Schema.Struct({ label = Schema.String(8), items = Schema.Array(Schema.U16, 4) })
	local schema: SchemaTypes.CompiledSchema?, schemaReason: string? = Compiler.Compile(definition)
	expect(schemaReason).toBeNil()
	assert(schema ~= nil, "Expected compiled schema")
	local codec: SchemaTypes.CompiledCodec?, codecReason: string? = Codecs.Compile(schema)
	expect(codecReason).toBeNil()
	assert(codec ~= nil, "Expected compiled codec")
	local value: any = { label = "KRF", items = { 1, 2 } }
	local measured: number?, reason: string? = codec.Measure(value)
	expect(reason).toBeNil()
	expect(capture(compile(definition), value, nil).encodedSizeBytes).toBe(measured)
end)

it("does not need Measure traversal solely to size a fixed-size schema", function()
	local originalCompile: typeof(Codecs.Compile) = Codecs.Compile
	local measureCalls: number = 0
	Codecs.Compile = function(schema: SchemaTypes.CompiledSchema): (SchemaTypes.CompiledCodec?, string?)
		local codec: SchemaTypes.CompiledCodec?, reason: string? = originalCompile(schema)
		if codec == nil then
			return nil, reason
		end
		return {
			fixedSizeBytes = codec.fixedSizeBytes,
			maxSizeBytes = codec.maxSizeBytes,
			Write = codec.Write,
			Read = codec.Read,
			Measure = function(value: any): (number?, string?)
				measureCalls += 1
				return codec.Measure(value)
			end,
		},
			nil
	end
	local success: boolean, failure: any = pcall(function()
		local plan: PublicationTypes.CapturePlan =
			compile(Schema.Struct({ active = Schema.Boolean, count = Schema.U16 }))
		expect(capture(plan, { active = true, count = 4 }, nil).encodedSizeBytes).toBe(3)
		expect(measureCalls).toBe(0)
	end)
	Codecs.Compile = originalCompile
	if not success then
		error(failure, 0)
	end
end)
