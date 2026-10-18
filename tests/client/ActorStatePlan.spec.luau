--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local StatePlan = require(KRF.client.Networking.utils.ActorStatePlan)
local SchemaUtils = require(script.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)

type Case = {
	name: string,
	schema: SharedNetworkingTypes.SchemaDefinition,
	previous: any,
	patch: SharedNetworkingTypes.ActorPatch,
	expected: any,
}

local cases: { Case } = {
	{
		name = "signed scalar replacement",
		schema = Schema.I16,
		previous = 0,
		patch = { kind = "Replace", value = -120 },
		expected = -120,
	},
	{
		name = "finite F32 replacement",
		schema = Schema.F32,
		previous = 1,
		patch = { kind = "Replace", value = 1.5 },
		expected = 1.5,
	},
	{
		name = "finite F64 replacement",
		schema = Schema.F64,
		previous = 1,
		patch = { kind = "Replace", value = 1.25 },
		expected = 1.25,
	},
	{
		name = "String replacement",
		schema = Schema.String(4),
		previous = "old",
		patch = { kind = "Replace", value = "new" },
		expected = "new",
	},
	{
		name = "Enum replacement",
		schema = Schema.Enum({ "A", "B" }),
		previous = "A",
		patch = { kind = "Replace", value = "B" },
		expected = "B",
	},
	{
		name = "scalar replacement",
		schema = Schema.U16,
		previous = 100,
		patch = { kind = "Replace", value = 75 },
		expected = 75,
	},
	{
		name = "false Boolean replacement",
		schema = Schema.Boolean,
		previous = true,
		patch = { kind = "Replace", value = false },
		expected = false,
	},
	{
		name = "nested Struct field",
		schema = Schema.Struct({
			detail = Schema.Struct({ count = Schema.U8, label = Schema.String(8) }),
			enabled = Schema.Boolean,
		}),
		previous = { detail = { count = 1, label = "same" }, enabled = true },
		patch = {
			kind = "Struct",
			fields = { detail = { kind = "Struct", fields = { count = { kind = "Replace", value = 2 } } } },
		},
		expected = { detail = { count = 2, label = "same" }, enabled = true },
	},
	{
		name = "Map add replace and remove",
		schema = Schema.Map(Schema.String(4), Schema.Struct({ count = Schema.U8 }), 3),
		previous = { A = { count = 1 }, B = { count = 2 }, C = { count = 3 } },
		patch = { kind = "Map", entries = { A = { count = 4 }, D = { count = 5 } }, removed = { "B", "C" } },
		expected = { A = { count = 4 }, D = { count = 5 } },
	},
	{
		name = "numeric Map keys",
		schema = Schema.Map(Schema.U8, Schema.Boolean, 2),
		previous = { [0] = true },
		patch = { kind = "Map", entries = { [1] = false }, removed = { 0 } },
		expected = { [1] = false },
	},
	{
		name = "Optional absent to present",
		schema = Schema.Optional(Schema.Struct({ count = Schema.U8 })),
		previous = nil,
		patch = { kind = "Replace", value = { count = 1 } },
		expected = { count = 1 },
	},
	{
		name = "Optional present to absent",
		schema = Schema.Optional(Schema.Struct({ count = Schema.U8 })),
		previous = { count = 1 },
		patch = { kind = "Replace", value = nil },
		expected = nil,
	},
	{
		name = "Optional present Struct diff",
		schema = Schema.Optional(Schema.Struct({ count = Schema.U8 })),
		previous = { count = 1 },
		patch = { kind = "Struct", fields = { count = { kind = "Replace", value = 2 } } },
		expected = { count = 2 },
	},
	{
		name = "Array whole replacement",
		schema = Schema.Array(Schema.U8, 3),
		previous = { 1, 2 },
		patch = { kind = "Replace", value = { 3 } },
		expected = { 3 },
	},
	{
		name = "Array empty replacement",
		schema = Schema.Array(Schema.U8, 3),
		previous = { 1 },
		patch = { kind = "Replace", value = {} },
		expected = {},
	},
	{
		name = "nested Optional removal",
		schema = Schema.Struct({ value = Schema.Optional(Schema.U8), count = Schema.U8 }),
		previous = { value = 2, count = 1 },
		patch = { kind = "Struct", fields = { value = { kind = "Replace", value = nil } } },
		expected = { count = 1 },
	},
}

for _, case: Case in cases do
	it("applies " .. case.name .. " and preserves the retained previous value", function()
		local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(case.schema))
		local snapshot: StatePlan.Result?, reason: string? = plan.Snapshot(case.previous)
		expect(reason).toBeNil()
		assert(snapshot ~= nil, "Expected admitted immutable snapshot")
		local result: StatePlan.Result?
		result, reason = plan.Apply(snapshot.value, case.patch)
		expect(reason).toBeNil()
		assert(result ~= nil, "Expected successful patch result including Optional nil")
		expect(result.value).toEqual(case.expected)
		expect(snapshot.value).toEqual(case.previous)

		if type(result.value) == "table" then
			expect(table.isfrozen(result.value)).toBe(true)
		end
	end)
end

it("owns recursively immutable snapshots without retaining mutable aliases", function()
	local schema: SharedNetworkingTypes.SchemaDefinition =
		Schema.Struct({ items = Schema.Array(Schema.Struct({ value = Schema.U8 }), 2) })

	local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(schema))
	local input: any = { items = { { value = 1 } } }
	local result: StatePlan.Result?, reason: string? = plan.Snapshot(input)
	expect(reason).toBeNil()
	assert(result ~= nil, "Expected owned snapshot")
	expect(table.isfrozen(result.value.items[1])).toBe(true)

	pcall(function()
		input.items[1].value = 9
	end)

	expect(result.value).toEqual({ items = { { value = 1 } } })
end)

it("copies only the changed Struct path and Map container while sharing untouched immutable values", function()
	local schema: SharedNetworkingTypes.SchemaDefinition = Schema.Struct({
		left = Schema.Struct({ count = Schema.U8 }),
		right = Schema.Map(Schema.String(4), Schema.Struct({ count = Schema.U8 }), 2),
	})

	local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(schema))

	local snapshot: StatePlan.Result?, reason: string? =
		plan.Snapshot({ left = { count = 1 }, right = { A = { count = 2 }, B = { count = 3 } } })

	assert(snapshot ~= nil, reason)
	local result: StatePlan.Result?

	result, reason = plan.Apply(
		snapshot.value,
		{ kind = "Struct", fields = { right = { kind = "Map", entries = { B = { count = 4 } }, removed = {} } } }
	)

	assert(result ~= nil, reason)
	expect(rawequal(result.value, snapshot.value)).toBe(false)
	expect(rawequal(result.value.right, snapshot.value.right)).toBe(false)
	expect(rawequal(result.value.left, snapshot.value.left)).toBe(true)
	expect(rawequal(result.value.right.A, snapshot.value.right.A)).toBe(true)
	expect(result.value.right.B.count).toBe(4)
	expect(snapshot.value.right.B.count).toBe(3)
end)

type InvalidCase = { name: string, schema: SharedNetworkingTypes.SchemaDefinition, previous: any, patch: any }

local invalidCases: { InvalidCase } = {
	{
		name = "unknown Struct field",
		schema = Schema.Struct({ count = Schema.U8 }),
		previous = { count = 1 },
		patch = { kind = "Struct", fields = { other = { kind = "Replace", value = 2 } } },
	},
	{
		name = "Map against scalar",
		schema = Schema.U8,
		previous = 1,
		patch = { kind = "Map", entries = {}, removed = {} },
	},
	{
		name = "Struct against absent Optional",
		schema = Schema.Optional(Schema.Struct({ count = Schema.U8 })),
		previous = nil,
		patch = { kind = "Struct", fields = { count = { kind = "Replace", value = 2 } } },
	},
	{
		name = "Map diff against absent Optional",
		schema = Schema.Optional(Schema.Map(Schema.U8, Schema.U8, 2)),
		previous = nil,
		patch = { kind = "Map", entries = { [1] = 2 }, removed = {} },
	},
	{
		name = "Array overflow",
		schema = Schema.Array(Schema.U8, 1),
		previous = { 1 },
		patch = { kind = "Replace", value = { 1, 2 } },
	},
	{
		name = "sparse Array",
		schema = Schema.Array(Schema.U8, 3),
		previous = { 1 },
		patch = { kind = "Replace", value = { [1] = 1, [3] = 2 } },
	},
	{
		name = "Array indexed patch",
		schema = Schema.Array(Schema.U8, 3),
		previous = { 1 },
		patch = { kind = "Struct", fields = { [1] = { kind = "Replace", value = 2 } } },
	},
	{
		name = "post-merge Map overflow",
		schema = Schema.Map(Schema.U8, Schema.U8, 2),
		previous = { [1] = 1, [2] = 2 },
		patch = { kind = "Map", entries = { [3] = 3 }, removed = {} },
	},
	{
		name = "overlapping Map removal",
		schema = Schema.Map(Schema.U8, Schema.U8, 2),
		previous = { [1] = 1 },
		patch = { kind = "Map", entries = { [1] = 2 }, removed = { 1 } },
	},
	{
		name = "duplicate Map removal",
		schema = Schema.Map(Schema.U8, Schema.U8, 2),
		previous = { [1] = 1 },
		patch = { kind = "Map", entries = {}, removed = { 1, 1 } },
	},
	{
		name = "Map key outside schema",
		schema = Schema.Map(Schema.U8, Schema.U8, 2),
		previous = { [1] = 1 },
		patch = { kind = "Map", entries = { bad = 1 }, removed = {} },
	},
	{ name = "integer overflow", schema = Schema.U8, previous = 1, patch = { kind = "Replace", value = 256 } },
	{ name = "nonfinite float", schema = Schema.F64, previous = 1, patch = { kind = "Replace", value = math.huge } },
	{
		name = "undeclared Enum",
		schema = Schema.Enum({ "A", "B" }),
		previous = "A",
		patch = { kind = "Replace", value = "C" },
	},
	{
		name = "oversized string",
		schema = Schema.String(2),
		previous = "A",
		patch = { kind = "Replace", value = "long" },
	},
	{
		name = "missing Struct fields",
		schema = Schema.Struct({ count = Schema.U8 }),
		previous = { count = 1 },
		patch = { kind = "Replace", value = {} },
	},
	{ name = "missing patch body", schema = Schema.U8, previous = 1, patch = {} },
	{ name = "unknown patch kind", schema = Schema.U8, previous = 1, patch = { kind = "Increment", value = 1 } },
}

for _, case: InvalidCase in invalidCases do
	it("rejects " .. case.name .. " without modifying the previous snapshot", function()
		local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(case.schema))
		local previous: StatePlan.Result?, reason: string? = plan.Snapshot(case.previous)
		assert(previous ~= nil, reason)
		local result: StatePlan.Result?
		result, reason = plan.Apply(previous.value, case.patch)
		expect(result).toBeNil()
		expect(reason).toBe("InvalidActorPatch")
		expect(previous.value).toEqual(case.previous)
	end)
end

it("rejects malformed complete truth independently of patch validation", function()
	local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(Schema.Struct({ count = Schema.U8 })))
	local result: StatePlan.Result?, reason: string? = plan.Snapshot({ count = "bad" })
	expect(result).toBeNil()
	expect(reason).toBe("InvalidActorState")
end)

it("rejects a Map operation against invalid local structure without leaking a raw indexing error", function()
	local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.U8, 2)))

	local result: StatePlan.Result?, reason: string? =
		plan.Apply("broken", { kind = "Map", entries = { [1] = 2 }, removed = {} })

	expect(result).toBeNil()
	expect(reason).toBe("InvalidActorPatch")
end)

it("owns composite replacement values without leaving mutable patch aliases into current truth", function()
	local plan: StatePlan.Plan =
		StatePlan.Compile(SchemaUtils.compile(Schema.Array(Schema.Struct({ count = Schema.U8 }), 2)))

	local replacement: any = { { count = 2 } }
	local previous: StatePlan.Result?, reason: string? = plan.Snapshot({ { count = 1 } })
	assert(previous ~= nil, reason)
	local result: StatePlan.Result?
	result, reason = plan.Apply(previous.value, { kind = "Replace", value = replacement })
	assert(result ~= nil, reason)
	expect(table.isfrozen(result.value)).toBe(true)
	expect(table.isfrozen(result.value[1])).toBe(true)

	pcall(function()
		replacement[1].count = 9
	end)

	expect(result.value).toEqual({ { count = 2 } })
	expect(previous.value).toEqual({ { count = 1 } })
end)

it("reuses equal immutable composite replacements and copies a replacement that removes Array entries", function()
	local plan: StatePlan.Plan = StatePlan.Compile(SchemaUtils.compile(Schema.Array(Schema.U8, 3)))
	local previous: StatePlan.Result?, reason: string? = plan.Snapshot({ 1, 2 })
	assert(previous ~= nil, reason)
	local equal: StatePlan.Result?
	equal, reason = plan.Apply(previous.value, { kind = "Replace", value = { 1, 2 } })
	assert(equal ~= nil, reason)
	expect(rawequal(equal.value, previous.value)).toBe(true)
	local shortened: StatePlan.Result?
	shortened, reason = plan.Apply(previous.value, { kind = "Replace", value = { 1 } })
	assert(shortened ~= nil, reason)
	expect(shortened.value).toEqual({ 1 })
	expect(previous.value).toEqual({ 1, 2 })
	expect(table.isfrozen(shortened.value)).toBe(true)
end)

it("treats equal Map entries and removal of an absent key as unchanged truth", function()
	local plan: StatePlan.Plan =
		StatePlan.Compile(SchemaUtils.compile(Schema.Map(Schema.U8, Schema.Struct({ count = Schema.U8 }), 3)))

	local previous: StatePlan.Result?, reason: string? = plan.Snapshot({ [1] = { count = 2 } })
	assert(previous ~= nil, reason)
	local result: StatePlan.Result?
	result, reason = plan.Apply(previous.value, { kind = "Map", entries = { [1] = { count = 2 } }, removed = { 2 } })
	assert(result ~= nil, reason)
	expect(rawequal(result.value, previous.value)).toBe(true)
	expect(rawequal(result.value[1], previous.value[1])).toBe(true)
end)
