--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach

local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionTypes = require(KRF.server.Action.types)

type ActionDefinition = ActionTypes.ActionDefinition

local preparedTagIds: { [string]: boolean } = {
	["Tag.Blocking"] = true,
	["Tag.Bleeding"] = true,
}

beforeEach(function()
	ActionRegistry._resetForTests()
end)

local function loadDefinition(definition: ActionDefinition): (boolean, string?)
	return ActionRegistry.Load({
		function(): ActionDefinition
			return definition
		end,
	}, preparedTagIds, {})
end

it("normalizes string and explicit Action Tag applications in declaration order", function()
	local definition: any = {
		id = "Action.Attack",
		visibility = "ServerOnly",
		activeTags = { "Tag.Blocking", { id = "Tag.Bleeding", duration = 3 } },
		appliedTags = { { id = "Tag.Bleeding", duration = 6 }, "Tag.Blocking" },
	}
	local loaded: boolean, reason: string? = loadDefinition(definition)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local result: any = ActionRegistry.Get("Action.Attack")
	expect(result.activeTags).toEqual({ { id = "Tag.Blocking" }, { id = "Tag.Bleeding", duration = 3 } })
	expect(result.appliedTags).toEqual({ { id = "Tag.Bleeding", duration = 6 }, { id = "Tag.Blocking" } })
end)

it("rejects unknown Tag ids in either declarative field before publishing", function()
	for _, field: string in { "activeTags", "appliedTags" } do
		local definition: any = { id = "Action.Attack", visibility = "ServerOnly" }
		definition[field] = { "Tag.Unknown" }
		local loaded: boolean, reason: string? = loadDefinition(definition)
		expect(loaded).toBe(false)
		expect(type(reason)).toBe("string")
		expect(reason).never.toBe("ActionFieldUnsupported:" .. field)
		expect(string.find(reason :: string, "Tag.Unknown", 1, true)).never.toBeNil()
		expect(ActionRegistry.IsLoaded()).toBe(false)
	end
end)

it("rejects malformed declarative Tag applications before publishing", function()
	local invalidEntries: { any } = {
		"",
		false,
		5,
		{ id = "" },
		{ id = 5 },
		{ id = "Tag.Bleeding", target = "OtherActor" },
		{ id = "Tag.Bleeding", duration = "6" },
		{ id = "Tag.Bleeding", duration = 0 },
		{ id = "Tag.Bleeding", duration = -1 },
		{ id = "Tag.Bleeding", duration = math.huge },
		{ id = "Tag.Bleeding", duration = 0 / 0 },
	}
	for _, field: string in { "activeTags", "appliedTags" } do
		for _, entry: any in invalidEntries do
			local definition: any = { id = "Action.Attack", visibility = "ServerOnly" }
			definition[field] = { entry }
			local loaded: boolean, reason: string? = loadDefinition(definition)
			expect(loaded).toBe(false)
			expect(type(reason)).toBe("string")
			expect(reason).never.toBe("ActionFieldUnsupported:" .. field)
			expect(ActionRegistry.IsLoaded()).toBe(false)
		end
	end
end)

it("requires declarative Tag fields to be dense arrays", function()
	local invalidCollections: { any } = {
		"Tag.Blocking",
		{ named = "Tag.Blocking" },
		{ [2] = "Tag.Blocking" },
		{ [1] = "Tag.Blocking", [3] = "Tag.Bleeding" },
	}
	for _, field: string in { "activeTags", "appliedTags" } do
		for _, collection: any in invalidCollections do
			local definition: any = { id = "Action.Attack", visibility = "ServerOnly" }
			definition[field] = collection
			local loaded: boolean, reason: string? = loadDefinition(definition)
			expect(loaded).toBe(false)
			expect(type(reason)).toBe("string")
			expect(reason).never.toBe("ActionFieldUnsupported:" .. field)
			expect(ActionRegistry.IsLoaded()).toBe(false)
		end
	end
end)

it("owns immutable copies of declarative Tag application arrays and entries", function()
	local entry: { id: string, duration: number } = { id = "Tag.Bleeding", duration = 6 }
	local activeTags: { any } = { entry }
	local definition: any = {
		id = "Action.Attack",
		visibility = "ServerOnly",
		activeTags = activeTags,
	}
	expect((loadDefinition(definition))).toBe(true)
	entry.id = "Tag.Unknown"
	entry.duration = 12
	activeTags[1] = "Tag.Blocking"
	local loaded: any = ActionRegistry.Get("Action.Attack")
	expect(loaded.activeTags).toEqual({ { id = "Tag.Bleeding", duration = 6 } })
	expect(table.isfrozen(loaded.activeTags)).toBe(true)
	expect(table.isfrozen(loaded.activeTags[1])).toBe(true)
end)

it("owns applied Tag options independently of source mutation", function()
	local entry: { id: string, duration: number } = { id = "Tag.Bleeding", duration = 4 }
	local source: any = {
		id = "Action.Attack",
		visibility = "ServerOnly",
		appliedTags = { entry },
	}
	expect((loadDefinition(source))).toBe(true)
	entry.id = "Tag.Blocking"
	entry.duration = 12
	source.appliedTags[1] = "Tag.Blocking"
	local loaded: any = ActionRegistry.Get("Action.Attack")
	expect(loaded.appliedTags).toEqual({ { id = "Tag.Bleeding", duration = 4 } })
	expect(table.isfrozen(loaded.appliedTags)).toBe(true)
	expect(table.isfrozen(loaded.appliedTags[1])).toBe(true)
end)
