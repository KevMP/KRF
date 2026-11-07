--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.ActionRequestTestUtils)

local function tagOf(entry: ActionRequestTypes.ActionRequestSchema, actionId: string?): number
	local id: string = actionId or "Game.Tagged"
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile({ [id] = entry })

	return TestUtils.request(catalog, id).contractTag
end

it("computes a U32 contract tag for every registered Action", function()
	local catalog: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(TestUtils.schemas())

	for _, actionId: string in catalog.actionIds do
		local tag: number = TestUtils.request(catalog, actionId).contractTag
		expect(tag % 1).toBe(0)
		expect(tag >= 0 and tag <= 4294967295).toBe(true)
	end
end)

it("computes the same tag for independently authored but structurally identical modules", function()
	local first: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(TestUtils.schemas())
	local second: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(TestUtils.schemas())

	for _, actionId: string in first.actionIds do
		expect(TestUtils.request(second, actionId).contractTag).toBe(TestUtils.request(first, actionId).contractTag)
	end
end)

it("does not depend on Struct field authoring order", function()
	local first: number = tagOf({ start = Schema.Struct({ alpha = Schema.U8, beta = Schema.U16 }) })
	local second: number = tagOf({ start = Schema.Struct({ beta = Schema.U16, alpha = Schema.U8 }) })
	expect(second).toBe(first)
end)

it("does not depend on which other Actions share the catalog", function()
	local alone: number = tagOf(TestUtils.schemas()["Combat.Fireball"], "Combat.Fireball")
	local shared: ActionRequestTypes.ActionRequestCatalog = TestUtils.compile(TestUtils.schemas())
	expect(TestUtils.request(shared, "Combat.Fireball").contractTag).toBe(alone)
end)

type DistinctCase = { label: string, entry: ActionRequestTypes.ActionRequestSchema, actionId: string? }

local baseline: ActionRequestTypes.ActionRequestSchema = {
	start = Schema.Struct({ power = Schema.U8 }),
	stop = { parameters = Schema.Struct({ charge = Schema.U8 }) },
	allowInputInterrupt = true,
	onDisconnect = "Interrupt",
}

local distinctCases: { DistinctCase } = {
	{ label = "the Action id", entry = baseline, actionId = "Game.Other" },
	{
		label = "the Start schema",
		entry = {
			start = Schema.Struct({ power = Schema.U16 }),
			stop = baseline.stop,
			allowInputInterrupt = true,
			onDisconnect = "Interrupt",
		},
	},
	{
		label = "the Stop parameter schema",
		entry = {
			start = baseline.start,
			stop = { parameters = Schema.Struct({ charge = Schema.F32 }) },
			allowInputInterrupt = true,
			onDisconnect = "Interrupt",
		},
	},
	{
		label = "a parameterless Stop instead of typed Stop parameters",
		entry = { start = baseline.start, stop = {}, allowInputInterrupt = true, onDisconnect = "Interrupt" },
	},
	{
		label = "a missing Stop path",
		entry = { start = baseline.start, allowInputInterrupt = true, onDisconnect = "Interrupt" },
	},
	{
		label = "Interrupt permission",
		entry = {
			start = baseline.start,
			stop = baseline.stop,
			allowInputInterrupt = false,
			onDisconnect = "Interrupt",
		},
	},
	{
		label = "the disconnect policy",
		entry = { start = baseline.start, stop = baseline.stop, allowInputInterrupt = true, onDisconnect = "Keep" },
	},
	{
		label = "the client release requirement",
		entry = {
			start = baseline.start,
			stop = baseline.stop,
			allowInputInterrupt = true,
			requiresClientRelease = true,
			onDisconnect = "Interrupt",
		},
	},
}

for _, distinct: DistinctCase in distinctCases do
	it("changes the tag when " .. distinct.label .. " changes", function()
		expect(tagOf(distinct.entry, distinct.actionId)).never.toBe(tagOf(baseline))
	end)
end
