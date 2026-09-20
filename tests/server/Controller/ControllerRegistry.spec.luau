--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)
local ControllerTypes = require(ReplicatedStorage.Packages.KRF.server.Controller.types)

type Actor = ActorTypes.Actor
type Controller = ActorTypes.Controller
type ControllerDef = ControllerTypes.ControllerDef
type ControllerRegistryT = ControllerTypes.ControllerRegistry

local ControllerRegistry: ControllerRegistryT =
	require(ReplicatedStorage.Packages.KRF.server.Controller.ControllerRegistry)

local function FactoryNoop(_actor: Actor): Controller
	return { Destroy = function() end }
end

it("loads a complete catalog and resolves dependencies with catalog order as the tie breaker", function()
	ControllerRegistry._ResetForTests()
	local definitions: { ControllerDef } = {
		{ key = "Dependent", factory = FactoryNoop, dependsOn = { "Root" } },
		{ key = "Other", factory = FactoryNoop },
		{ key = "Root", factory = FactoryNoop },
		{ key = "Final", factory = FactoryNoop, dependsOn = { "Dependent", "Other" } },
	}
	local loaded: boolean, reason: string? = ControllerRegistry.Load(definitions)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(ControllerRegistry.IsLoaded()).toBe(true)
	expect(ControllerRegistry.GetKeys()).toEqual({ "Dependent", "Other", "Root", "Final" })

	local ordered: { string }?, orderReason: string? =
		ControllerRegistry.ResolveOrder({ "Final", "Root", "Other", "Dependent", "Root" })
	expect(orderReason).toBeNil()
	expect(ordered).toEqual({ "Other", "Root", "Dependent", "Final" })
	local reordered: { string }?, reorderedReason: string? =
		ControllerRegistry.ResolveOrder({ "Dependent", "Other", "Final", "Root" })
	expect(reorderedReason).toBeNil()
	expect(reordered).toEqual({ "Other", "Root", "Dependent", "Final" })
	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder ignores duplicate input keys", function()
	ControllerRegistry._ResetForTests()
	local controllerDefA: ControllerDef = { key = "A", factory = FactoryNoop }
	local controllerDefB: ControllerDef = { key = "B", factory = FactoryNoop }
	local loaded: boolean, loadReason: string? = ControllerRegistry.Load({ controllerDefA, controllerDefB })
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({ "B", "A", "A", "B" })
	expect(resolveReason).toBeNil()
	expect(orderedKeys).toEqual({ "A", "B" })
	ControllerRegistry._ResetForTests()
end)

it("rejects duplicate keys atomically and accepts a corrected catalog", function()
	ControllerRegistry._ResetForTests()
	local duplicate: ControllerDef = { key = "Same", factory = FactoryNoop }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ duplicate, duplicate })
	expect(loaded).toBe(false)
	expect(reason).toBe("DuplicateControllerKey")
	expect(ControllerRegistry.IsLoaded()).toBe(false)
	expect(ControllerRegistry.Get("Same")).toBeNil()
	expect(ControllerRegistry.GetKeys()).toEqual({})

	loaded, reason = ControllerRegistry.Load({ duplicate })
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(ControllerRegistry.Get("Same")).never.toBeNil()
	ControllerRegistry._ResetForTests()
end)

it("rejects invalid definitions before exposing any controller", function()
	ControllerRegistry._ResetForTests()
	local valid: ControllerDef = { key = "Valid", factory = FactoryNoop }
	local invalid: ControllerDef = { key = "", factory = FactoryNoop }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ valid, invalid })
	expect(loaded).toBe(false)
	expect(reason).toBe("ControllerKeyCannotBeEmpty")
	expect(ControllerRegistry.IsLoaded()).toBe(false)
	expect(ControllerRegistry.Get("Valid")).toBeNil()
	ControllerRegistry._ResetForTests()
end)

it("rejects malformed catalog entries without publishing a partial catalog", function()
	local malformedCases: { { definitions: any, reason: string } } = {
		{ definitions = "invalid", reason = "ControllerCatalogMustBeTable" },
		{ definitions = { false }, reason = "ControllerDefinitionMustBeTable" },
		{ definitions = { {} }, reason = "ControllerKeyMissing" },
		{ definitions = { { key = 1 } }, reason = "ControllerKeyMustBeString" },
		{ definitions = { { key = "Bad" } }, reason = "ControllerFactoryMustBeFunction" },
		{
			definitions = { { key = "Bad", factory = FactoryNoop, autoAttach = "yes" } },
			reason = "ControllerAutoAttachMustBeBoolean",
		},
		{
			definitions = { { key = "Bad", factory = FactoryNoop, dependsOn = "Other" } },
			reason = "ControllerDependenciesMustBeTable",
		},
		{
			definitions = { { key = "Bad", factory = FactoryNoop, dependsOn = { false } } },
			reason = "ControllerDependencyKeyInvalid",
		},
	}

	for _, case in malformedCases do
		ControllerRegistry._ResetForTests()
		local loaded: boolean, reason: string? = ControllerRegistry.Load(case.definitions)
		expect(loaded).toBe(false)
		expect(reason).toBe(case.reason)
		expect(ControllerRegistry.IsLoaded()).toBe(false)
		expect(ControllerRegistry.GetKeys()).toEqual({})
	end
	ControllerRegistry._ResetForTests()
end)

it("rejects missing dependencies and cycles during load", function()
	ControllerRegistry._ResetForTests()
	local missing: ControllerDef = { key = "NeedsMissing", factory = FactoryNoop, dependsOn = { "Missing" } }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ missing })
	expect(loaded).toBe(false)
	expect(reason).toBe("MissingDependency:NeedsMissing->Missing")
	expect(ControllerRegistry.IsLoaded()).toBe(false)

	local first: ControllerDef = { key = "First", factory = FactoryNoop, dependsOn = { "Second" } }
	local second: ControllerDef = { key = "Second", factory = FactoryNoop, dependsOn = { "Third" } }
	local third: ControllerDef = { key = "Third", factory = FactoryNoop, dependsOn = { "First" } }
	local unrelated: ControllerDef = { key = "Unrelated", factory = FactoryNoop }
	local unrelatedDependent: ControllerDef = {
		key = "UnrelatedDependent",
		factory = FactoryNoop,
		dependsOn = { "Unrelated" },
	}
	loaded, reason = ControllerRegistry.Load({ first, unrelated, third, unrelatedDependent, second })
	expect(loaded).toBe(false)
	expect(reason).toBe("CyclicDependency")
	expect(ControllerRegistry.IsLoaded()).toBe(false)
	expect(ControllerRegistry.Get("First")).toBeNil()
	expect(ControllerRegistry.Get("Unrelated")).toBeNil()
	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.GetAutoAttachKeys respects default and explicit attachment in catalog order", function()
	ControllerRegistry._ResetForTests()
	local defaultDefinition: ControllerDef = { key = "Default", factory = FactoryNoop }
	local explicitDefinition: ControllerDef = { key = "ExplicitTrue", factory = FactoryNoop, autoAttach = true }
	local disabledDefinition: ControllerDef = { key = "False", factory = FactoryNoop, autoAttach = false }
	local loaded: boolean, reason: string? =
		ControllerRegistry.Load({ defaultDefinition, explicitDefinition, disabledDefinition })
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(ControllerRegistry.GetAutoAttachKeys()).toEqual({ "Default", "ExplicitTrue" })
	ControllerRegistry._ResetForTests()
end)

it("rejects a second load without changing the published catalog", function()
	ControllerRegistry._ResetForTests()
	local first: ControllerDef = { key = "First", factory = FactoryNoop }
	local second: ControllerDef = { key = "Second", factory = FactoryNoop }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ first })
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	loaded, reason = ControllerRegistry.Load({ second })
	expect(loaded).toBe(false)
	expect(reason).toBe("ControllerDefinitionsAlreadyLoaded")
	expect(ControllerRegistry.GetKeys()).toEqual({ "First" })
	expect(ControllerRegistry.Get("Second")).toBeNil()
	ControllerRegistry._ResetForTests()
end)

it("copies definitions and returns defensive key arrays", function()
	ControllerRegistry._ResetForTests()
	local dependencies: { string } = { "Root" }
	local root: ControllerDef = { key = "Root", factory = FactoryNoop }
	local dependent: ControllerDef = { key = "Dependent", factory = FactoryNoop, dependsOn = dependencies }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ root, dependent })
	expect(loaded).toBe(true)
	expect(reason).toBeNil()

	dependent.autoAttach = false
	table.clear(dependencies)
	local keys: { string } = ControllerRegistry.GetKeys()
	local autoAttachKeys: { string } = ControllerRegistry.GetAutoAttachKeys()
	table.clear(keys)
	table.clear(autoAttachKeys)
	expect(ControllerRegistry.GetKeys()).toEqual({ "Root", "Dependent" })
	expect(ControllerRegistry.GetAutoAttachKeys()).toEqual({ "Root", "Dependent" })
	expect((ControllerRegistry.Get("Dependent") :: ControllerDef).dependsOn).toEqual({ "Root" })
	ControllerRegistry._ResetForTests()
end)

it("preserves subset dependency rules and ignores repeated dependencies", function()
	ControllerRegistry._ResetForTests()
	local root: ControllerDef = { key = "Root", factory = FactoryNoop, autoAttach = false }
	local dependent: ControllerDef = { key = "Dependent", factory = FactoryNoop, dependsOn = { "Root", "Root" } }
	local loaded: boolean, reason: string? = ControllerRegistry.Load({ dependent, root })
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	expect(ControllerRegistry.GetAutoAttachKeys()).toEqual({ "Dependent" })

	local ordered: { string }?, orderReason: string? = ControllerRegistry.ResolveOrder({ "Dependent" })
	expect(ordered).toBeNil()
	expect(orderReason).toBe("DependencyNotInAttachSet:Dependent->Root")
	ordered, orderReason = ControllerRegistry.ResolveOrder({ "Dependent", "Root" })
	expect(orderReason).toBeNil()
	expect(ordered).toEqual({ "Root", "Dependent" })
	ControllerRegistry._ResetForTests()
end)

it("resolves an empty request and rejects unknown requested keys", function()
	ControllerRegistry._ResetForTests()
	local ordered: { string }?, reason: string? = ControllerRegistry.ResolveOrder({})
	expect(reason).toBeNil()
	expect(ordered).toEqual({})
	ordered, reason = ControllerRegistry.ResolveOrder({ "Unknown" })
	expect(ordered).toBeNil()
	expect(reason).toBe("UnknownControllerKey:Unknown")
	ControllerRegistry._ResetForTests()
end)
