--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach

local ActionTypes: any = require(KRF.server.Action.types)
local ActionRegistry = require(KRF.server.Action.ActionRegistry)

type ActionDefinition = ActionTypes.ActionDefinition
type InternalActionRegistry = ActionTypes.InternalActionRegistry
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition

local Registry: InternalActionRegistry = ActionRegistry
local preparedTagIds: { [string]: boolean } = { ["Tag.Grounded"] = true }
local preparedResourceIds: { [string]: boolean } = { ["Resource.Stamina"] = true }

beforeEach(function()
	Registry._resetForTests()
end)

local function createAction(id: string): ActionDefinition
	return { id = id, visibility = "ServerOnly" }
end

local function loadDefinitions(
	definitions: { ActionDefinition },
	tags: { [string]: boolean },
	resources: { [string]: boolean }
): (boolean, string?)
	local factories: { ActionTypes.ActionFactory } = {}
	for _, definition: ActionDefinition in definitions do
		local source: ActionDefinition = definition
		table.insert(factories, function(): ActionDefinition
			return table.clone(source)
		end)
	end
	return Registry.Load(factories, tags, resources)
end

it("loads minimal and fully populated Action definitions in declaration order", function()
	local first: ActionDefinition = createAction("Action.Dodge")
	local second: ActionDefinition = createAction("Action.Roll")
	second.autoGrant = true
	second.requiredTags = { "Tag.Grounded" }
	second.costs = { ["Resource.Stamina"] = 15 }
	second.locks = { "Locomotion" }
	second.interruptibleBy = { "Action.Dodge" }
	local loaded: boolean, reason: string? = loadDefinitions({ first, second }, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(Registry.IsLoaded()).toBe(true)
	local all: { LoadedActionDefinition } = Registry.GetAll()
	expect(all[1].id).toBe("Action.Dodge")
	expect(all[2].id).toBe("Action.Roll")
	expect(all[1].autoGrant).toBe(false)
	expect(all[1].requiredTags).toEqual({})
	expect(all[1].blockedTags).toEqual({})
	expect(all[1].costs).toEqual({})
	expect(all[1].locks).toEqual({})
	expect(all[1].interruptibleBy).toEqual({})
end)

it("does not publish partial Action state when a later definition is invalid", function()
	local invalid: any = createAction("Action.Invalid")
	invalid.visibility = "Everyone"
	local loaded: boolean, reason: string? =
		loadDefinitions({ createAction("Action.Dodge"), invalid }, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(false)
	expect(reason).toBe("ActionVisibilityInvalid")
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("Action.Dodge")).toBeNil()
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
end)

it("validates Action-to-Action references against the complete catalog rather than declaration order", function()
	local first: ActionDefinition = createAction("Action.First")
	first.interruptibleBy = { "Action.Second" }
	local loaded: boolean, reason: string? =
		loadDefinitions({ first, createAction("Action.Second") }, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end)

it("provides complete hit, miss, ordered, and keyed read surfaces", function()
	local loaded: boolean, reason: string? = loadDefinitions(
		{ createAction("Action.Dodge"), createAction("Action.Roll") },
		preparedTagIds,
		preparedResourceIds
	)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local dodge: LoadedActionDefinition = Registry.Get("Action.Dodge") :: LoadedActionDefinition
	local roll: LoadedActionDefinition = Registry.Get("Action.Roll") :: LoadedActionDefinition
	expect(dodge.id).toBe("Action.Dodge")
	expect(Registry.Get("Action.Unknown")).toBeNil()
	expect(Registry.GetAll()).toEqual({ dodge, roll })
	expect(Registry.GetAllById()["Action.Dodge"]).toBe(dodge)
	expect(Registry.GetAllById()["Action.Roll"]).toBe(roll)
end)

it("owns immutable normalized copies rather than consumer source or registry read tables", function()
	local definition: ActionDefinition = createAction("Action.Dodge")
	definition.requiredTags = { "Tag.Grounded" }
	definition.costs = { ["Resource.Stamina"] = 15 }
	definition.locks = { "Locomotion" }
	local sourceCatalog: { ActionDefinition } = { definition }
	local loaded: boolean, reason: string? = loadDefinitions(sourceCatalog, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	definition.id = "Action.Mutated"
	(definition.requiredTags :: { string })[1] = "Tag.Mutated"
	(definition.costs :: { [string]: number })["Resource.Stamina"] = 99
	table.insert(definition.locks :: { string }, "Mutated")
	table.clear(sourceCatalog)
	local loadedDefinition: LoadedActionDefinition = Registry.Get("Action.Dodge") :: LoadedActionDefinition
	expect(loadedDefinition.requiredTags).toEqual({ "Tag.Grounded" })
	expect(loadedDefinition.costs).toEqual({ ["Resource.Stamina"] = 15 })
	expect(loadedDefinition.locks).toEqual({ "Locomotion" })
	expect(Registry.Get("Action.Mutated")).toBeNil()
	local definitionMutable: boolean = pcall(function()
		(loadedDefinition :: any).autoGrant = true
	end)
	expect(definitionMutable).toBe(false)
	local tagsMutable: boolean = pcall(function()
		(loadedDefinition.requiredTags :: { string })[1] = "Tag.Mutated"
	end)
	expect(tagsMutable).toBe(false)
	local arrayMutable: boolean = pcall(function()
		Registry.GetAll()[1] = loadedDefinition
	end)
	expect(arrayMutable).toBe(false)
	local mapMutable: boolean = pcall(function()
		Registry.GetAllById()["Action.Other"] = loadedDefinition
	end)
	expect(mapMutable).toBe(false)
end)

it("rejects a second catalog load after publication", function()
	local loaded: boolean = loadDefinitions({}, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	local secondLoaded: boolean, reason: string? = loadDefinitions({}, preparedTagIds, preparedResourceIds)
	expect(secondLoaded).toBe(false)
	expect(reason).toBe("ActionDefinitionsAlreadyLoaded")
end)

it("keeps loaded definitions metadata-only and snapshots execution hooks", function()
	local hookCalls: number = 0
	local definition: any = createAction("Action.Dodge")
	definition.autoGrant = false
	definition.blockedTags = { "Tag.Grounded" }
	definition.interruptibleBy = { "Action.Dodge" }
	local hookFields: { string } =
		{ "onCanStart", "onStart", "onStopRequested", "onUpdate", "onEnd", "onInterrupt", "canBeInterruptedBy" }
	for _, field: string in hookFields do
		definition[field] = function(): boolean
			hookCalls += 1
			return true
		end
	end
	local loaded: boolean, reason: string? = loadDefinitions({ definition }, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local loadedDefinition: LoadedActionDefinition = Registry.Get("Action.Dodge") :: LoadedActionDefinition
	expect(loadedDefinition.autoGrant).toBe(false)
	local implementation, executionReason = Registry.CreateExecution("Action.Dodge")
	expect(executionReason).toBeNil()
	expect(implementation).never.toBeNil()
	for _, field: string in hookFields do
		expect((loadedDefinition :: any)[field]).toBeNil()
		expect((implementation :: any)[field]).toBe(definition[field])
		definition[field] = nil
		expect(type((implementation :: any)[field])).toBe("function")
	end
	definition.blockedTags[1] = "Tag.Mutated"
	definition.interruptibleBy[1] = "Action.Mutated"
	expect(loadedDefinition.blockedTags).toEqual({ "Tag.Grounded" })
	expect(loadedDefinition.interruptibleBy).toEqual({ "Action.Dodge" })
	for _, field: string in { "requiredTags", "blockedTags", "costs", "locks", "interruptibleBy" } do
		local collectionMutable: boolean = pcall(function()
			table.clear((loadedDefinition :: any)[field])
		end)
		expect(collectionMutable).toBe(false)
	end
	expect(hookCalls).toBe(0)
end)

it("rejects duplicate ids without publishing and permits a corrected catalog to load", function()
	local loaded: boolean, reason: string? = loadDefinitions(
		{ createAction("Action.Dodge"), createAction("Action.Dodge") },
		preparedTagIds,
		preparedResourceIds
	)
	expect(loaded).toBe(false)
	expect(reason).toBe("ActionIdAlreadyRegistered")
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.GetAllById()).toEqual({})
	local arrayMutable: boolean = pcall(function()
		table.clear(Registry.GetAll())
	end)
	local mapMutable: boolean = pcall(function()
		table.clear(Registry.GetAllById())
	end)
	expect(arrayMutable).toBe(false)
	expect(mapMutable).toBe(false)
	loaded, reason = loadDefinitions({ createAction("Action.Dodge") }, preparedTagIds, preparedResourceIds)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local loadedDefinition: LoadedActionDefinition = Registry.Get("Action.Dodge") :: LoadedActionDefinition
	expect(loadedDefinition.id).toBe("Action.Dodge")
end)

it("rejects malformed factory catalogs and factory failures before publication", function()
	local cases: { { any } } = {
		{ 4, "ActionDefinitionsMustBeTable" },
		{ {
			[2] = function()
				return createAction("Action.A")
			end,
		}, "ActionDefinitionsMustBeArray" },
		{ {
			["named"] = function()
				return createAction("Action.A")
			end,
		}, "ActionDefinitionsMustBeArray" },
		{ { false }, "ActionFactoryMustBeFunction" },
		{ {
			function()
				error("factory boom")
			end,
		}, "ActionFactoryFailed" },
		{ {
			function()
				task.wait()
			end,
		}, "ActionFactoryYielded" },
		{ {
			function()
				return nil
			end,
		}, "ActionDefinitionMissing" },
		{ {
			function()
				return 4
			end,
		}, "ActionDefinitionMustBeTable" },
	}
	for _, case in cases do
		local loaded: boolean, reason: string? = Registry.Load(case[1], preparedTagIds, preparedResourceIds)
		expect(loaded).toBe(false)
		expect(reason).toBe(case[2])
		expect(Registry.IsLoaded()).toBe(false)
	end
end)

it("stages one startup result and publishes that result without calling factories twice", function()
	local calls: number = 0
	local factory = function(): ActionDefinition
		calls += 1
		return createAction("Action.Dodge")
	end
	local prepared, reason = Registry.Prepare({ factory }, preparedTagIds, preparedResourceIds)
	expect(reason).toBeNil()
	expect(calls).toBe(1)
	expect(Registry.IsLoaded()).toBe(false)
	expect((Registry.Publish(prepared :: ActionTypes.PreparedActionCatalog))).toBe(true)
	expect(calls).toBe(1)
	expect(Registry.Get("Action.Dodge")).never.toBeNil()
	expect((Registry.Publish(prepared :: ActionTypes.PreparedActionCatalog))).toBe(false)
	local later, laterReason = Registry.Prepare({ factory }, preparedTagIds, preparedResourceIds)
	expect(later).toBeNil()
	expect(laterReason).toBe("ActionDefinitionsAlreadyLoaded")
end)

it("rejects an unknown execution id and an invalid per-request factory result", function()
	local mode: string = "valid"
	local factory = function(): ActionDefinition
		if mode == "valid" then
			return createAction("Action.Dodge")
		elseif mode == "unsupported" then
			return { id = "Action.Dodge", visibility = "ServerOnly", new = function() end } :: any
		end
		return { id = "Action.Other", visibility = "ServerOnly" }
	end
	expect((Registry.Load({ factory }, preparedTagIds, preparedResourceIds))).toBe(true)
	local missing, missingReason = Registry.CreateExecution("Action.Unknown")
	expect(missing).toBeNil()
	expect(missingReason).toBe("UnknownActionId:Action.Unknown")
	mode = "wrong id"
	local implementation, reason = Registry.CreateExecution("Action.Dodge")
	expect(implementation).toBeNil()
	expect(reason).toBe("ActionFactoryInvalidResult")
	mode = "unsupported"
	implementation, reason = Registry.CreateExecution("Action.Dodge")
	expect(implementation).toBeNil()
	expect(reason).toBe("ActionFactoryInvalidResult")
end)
