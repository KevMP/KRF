--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local ActorUtils = require(script.Parent.Utils.ActorViewTestUtils)
local TestUtils = require(script.Parent.Utils.ActionsViewTestUtils)

local fixture: ActorUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	ActorUtils.destroy(fixture)
end)

it("returns a stable frozen facade with only queries and read-only Event surfaces", function()
	local actor: Types.ActorView = TestUtils.baseline(fixture, { [1] = "Action.A" })
	local actions: TestUtils.ActionsView = TestUtils.get(actor)
	expect(TestUtils.get(actor)).toBe(actions)
	expect(table.isfrozen(actions)).toBe(true)
	local fields: { string } = {}

	for key: string in actions :: any do
		table.insert(fields, key)
	end

	table.sort(fields)

	expect(fields).toEqual({
		"GetAction",
		"GetActiveActions",
		"IsActionActive",
		"OnActionEnded",
		"OnActionInterrupted",
		"OnActionStarted",
		"OnStateChanged",
	})

	for _, name: string in { "OnActionStarted", "OnActionEnded", "OnActionInterrupted", "OnStateChanged" } do
		local event: any = (actions :: any)[name]

		expect((pcall(function()
			return event.Fire
		end))).toBe(false)

		expect((pcall(function()
			return event.Destroy
		end))).toBe(false)
	end

	expect((pcall(function()
		(actions :: any).RequestAction = function() end
	end))).toBe(false)
end)

it("preserves duplicate ids as distinct immutable sequence snapshots in ascending numeric order", function()
	local actor: Types.ActorView =
		TestUtils.baseline(fixture, { [44] = "Action.A", [2] = "Action.B", [11] = "Action.A" })

	local actions: TestUtils.ActionsView = TestUtils.get(actor)
	local active: { TestUtils.Snapshot } = actions:GetActiveActions()

	expect(active).toEqual({
		{ actionId = "Action.B", sequenceId = 2 },
		{ actionId = "Action.A", sequenceId = 11 },
		{ actionId = "Action.A", sequenceId = 44 },
	})

	expect(table.isfrozen(active)).toBe(true)

	for _, snapshot: TestUtils.Snapshot in active do
		expect(table.isfrozen(snapshot)).toBe(true)

		expect((pcall(function()
			(snapshot :: any).actionId = "Forged"
		end))).toBe(false)
	end

	expect(actions:GetAction(11)).toEqual({ actionId = "Action.A", sequenceId = 11 })
	expect(actions:GetAction(12)).toBeNil()
	expect(actions:IsActionActive("Action.A")).toBe(true)
	expect(actions:IsActionActive("Action.B")).toBe(true)
	expect(actions:IsActionActive("Private.Secret")).toBe(false)
end)

it(
	"keeps an Action active until the final matching instance leaves and retained snapshots remain historical identity",
	function()
		local actions: TestUtils.ActionsView =
			TestUtils.get(TestUtils.baseline(fixture, { [1] = "Action.A", [2] = "Action.A" }))

		local retained: TestUtils.Snapshot? = actions:GetAction(1)
		ActorUtils.commit(fixture, 11, { TestUtils.patch({}, { 1 }) }, { TestUtils.event("Ended", "Action.A", 1) })
		expect(actions:GetAction(1)).toBeNil()
		expect(actions:IsActionActive("Action.A")).toBe(true)
		expect(actions:GetAction(2)).toEqual({ actionId = "Action.A", sequenceId = 2 })

		ActorUtils.commit(
			fixture,
			12,
			{ TestUtils.patch({}, { 2 }) },
			{ TestUtils.event("Interrupted", "Action.A", 2) }
		)

		expect(actions:IsActionActive("Action.A")).toBe(false)
		expect(actions:GetActiveActions()).toEqual({})
		expect(retained).toEqual({ actionId = "Action.A", sequenceId = 1 })
	end
)

it("provides a permanently empty stable ActionsView when bootstrap has no Actions domain", function()
	ActorUtils.destroy(fixture)

	fixture = ActorUtils.new(nil, { version = TestUtils.manifest().version, domains = {} })
	ActorUtils.baseline(fixture, nil, nil, nil, {})
	local actor: Types.ActorView = ActorUtils.view(fixture)
	local actions: TestUtils.ActionsView = TestUtils.get(actor)
	expect(actions:GetActiveActions()).toEqual({})
	expect(actions:IsActionActive("Action.A")).toBe(false)
	expect(actions:GetAction(1)).toBeNil()
	ActorUtils.baseline(fixture, 1, nil, 50, {}, 2)
	expect(TestUtils.get(actor)).toBe(actions)
	expect(actions:GetActiveActions()).toEqual({})
end)

it("preserves U32 maximum sequence identity through ordinary baseline encoding and typed lookup", function()
	local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, { [4294967295] = "Action.A" }))
	expect(actions:GetAction(4294967295)).toEqual({ actionId = "Action.A", sequenceId = 4294967295 })
	expect(actions:GetAction(0)).toBeNil()
	expect(actions:GetAction(4294967296)).toBeNil()
end)
