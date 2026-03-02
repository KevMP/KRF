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
	local controller: Controller = {
		Destroy = function() end,
	}
	return controller
end

it("ControllerRegistry.Register rejects duplicate controller keys", function()
	ControllerRegistry._ResetForTests()

	local controllerDef1: ControllerDef = {
		key = "TestController",
		factory = FactoryNoop,
	}

	local controllerDef2: ControllerDef = {
		key = "TestController",
		factory = FactoryNoop,
	}

	local ok1: boolean, reason1: string? = ControllerRegistry.Register(controllerDef1)
	local ok2: boolean, reason2: string? = ControllerRegistry.Register(controllerDef2)

	expect(ok1).toBe(true)
	expect(reason1).toBeNil()

	expect(ok2).toBe(false)
	expect(reason2).toBe("DuplicateControllerKey")

	local stored: ControllerDef? = ControllerRegistry.Get("TestController")
	expect(stored).toBe(controllerDef1)

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder returns a deterministic topological order", function()
	ControllerRegistry._ResetForTests()

	-- Graph:
	-- A
	-- ├─ B (depends on A)
	-- ├─ C (depends on A)
	-- └─ D (depends on B, C)
	--
	-- Expected deterministic order (given registration order A, B, C, D):
	-- A, B, C, D

	local controllerDefA: ControllerDef = {
		key = "A",
		factory = FactoryNoop,
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		factory = FactoryNoop,
		dependsOn = { "A" },
	}

	local controllerDefC: ControllerDef = {
		key = "C",
		factory = FactoryNoop,
		dependsOn = { "A" },
	}

	local controllerDefD: ControllerDef = {
		key = "D",
		factory = FactoryNoop,
		dependsOn = { "B", "C" },
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)
	local okC: boolean, reasonC: string? = ControllerRegistry.Register(controllerDefC)
	local okD: boolean, reasonD: string? = ControllerRegistry.Register(controllerDefD)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()
	expect(okC).toBe(true)
	expect(reasonC).toBeNil()
	expect(okD).toBe(true)
	expect(reasonD).toBeNil()

	-- Call with scrambled input order (should not matter)
	local orderedKeys1: { string }?, resolveReason1: string? = ControllerRegistry.ResolveOrder({ "D", "C", "B", "A" })

	expect(resolveReason1).toBeNil()
	expect(orderedKeys1).toEqual({ "A", "B", "C", "D" })

	-- Call again with a different scrambled order to prove determinism
	local orderedKeys2: { string }?, resolveReason2: string? = ControllerRegistry.ResolveOrder({ "B", "D", "A", "C" })

	expect(resolveReason2).toBeNil()
	expect(orderedKeys2).toEqual({ "A", "B", "C", "D" })

	-- Sanity: ensure result contains only candidate keys and has the right length
	expect(#(orderedKeys2 :: { string })).toBe(4)

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder rejects unknown controller keys", function()
	ControllerRegistry._ResetForTests()

	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({ "NotRegistered" })

	expect(orderedKeys).toBeNil()
	expect(resolveReason).toBe("UnknownControllerKey:NotRegistered")

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder ignores duplicate input keys", function()
	ControllerRegistry._ResetForTests()

	local controllerDefA: ControllerDef = {
		key = "A",
		factory = FactoryNoop,
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		factory = FactoryNoop,
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()

	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({ "B", "A", "A", "B" })

	expect(resolveReason).toBeNil()
	expect(orderedKeys).toEqual({ "A", "B" })

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder rejects cycles even when other controllers are acyclic", function()
	ControllerRegistry._ResetForTests()

	-- Cycle: A -> B -> C -> A
	local controllerDefA: ControllerDef = {
		key = "A",
		factory = FactoryNoop,
		dependsOn = { "B" },
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		factory = FactoryNoop,
		dependsOn = { "C" },
	}

	local controllerDefC: ControllerDef = {
		key = "C",
		factory = FactoryNoop,
		dependsOn = { "A" },
	}

	-- Acyclic chain: D -> E
	local controllerDefD: ControllerDef = {
		key = "D",
		factory = FactoryNoop,
	}

	local controllerDefE: ControllerDef = {
		key = "E",
		factory = FactoryNoop,
		dependsOn = { "D" },
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)
	local okC: boolean, reasonC: string? = ControllerRegistry.Register(controllerDefC)
	local okD: boolean, reasonD: string? = ControllerRegistry.Register(controllerDefD)
	local okE: boolean, reasonE: string? = ControllerRegistry.Register(controllerDefE)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()
	expect(okC).toBe(true)
	expect(reasonC).toBeNil()
	expect(okD).toBe(true)
	expect(reasonD).toBeNil()
	expect(okE).toBe(true)
	expect(reasonE).toBeNil()

	-- Scrambled input order to ensure behavior doesn't depend on input ordering
	local orderedKeys: { string }?, resolveReason: string? =
		ControllerRegistry.ResolveOrder({ "E", "C", "D", "B", "A" })

	expect(orderedKeys).toBeNil()
	expect(resolveReason).toBe("CyclicDependency")

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder rejects dependencies outside the requested set", function()
	ControllerRegistry._ResetForTests()

	local controllerDefA: ControllerDef = {
		key = "A",
		factory = FactoryNoop,
		autoAttach = false,
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		factory = FactoryNoop,
		dependsOn = { "A" },
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()

	-- Candidate set excludes A, but B depends on A -> reject
	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({ "B" })

	expect(orderedKeys).toBeNil()
	expect(resolveReason).toBe("DependencyNotInAttachSet:B->A")

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.GetAutoAttachKeys respects default attachment and preserves registration order", function()
	ControllerRegistry._ResetForTests()

	local controllerDefDefault: ControllerDef = {
		key = "Default",
		factory = FactoryNoop,
		-- autoAttach omitted => default true
	}

	local controllerDefExplicitTrue: ControllerDef = {
		key = "ExplicitTrue",
		factory = FactoryNoop,
		autoAttach = true,
	}

	local controllerDefFalse: ControllerDef = {
		key = "False",
		factory = FactoryNoop,
		autoAttach = false,
	}

	local ok1: boolean, reason1: string? = ControllerRegistry.Register(controllerDefDefault)
	local ok2: boolean, reason2: string? = ControllerRegistry.Register(controllerDefExplicitTrue)
	local ok3: boolean, reason3: string? = ControllerRegistry.Register(controllerDefFalse)

	expect(ok1).toBe(true)
	expect(reason1).toBeNil()
	expect(ok2).toBe(true)
	expect(reason2).toBeNil()
	expect(ok3).toBe(true)
	expect(reason3).toBeNil()

	local autoAttachKeys: { string } = ControllerRegistry.GetAutoAttachKeys()
	expect(autoAttachKeys).toEqual({ "Default", "ExplicitTrue" })

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder returns an empty order for an empty request", function()
	ControllerRegistry._ResetForTests()

	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({})

	expect(resolveReason).toBeNil()
	expect(orderedKeys).toEqual({})

	ControllerRegistry._ResetForTests()
end)

it("ControllerRegistry.ResolveOrder ignores duplicate dependencies", function()
	ControllerRegistry._ResetForTests()

	local controllerDefA: ControllerDef = {
		key = "A",
		factory = FactoryNoop,
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		factory = FactoryNoop,
		dependsOn = { "A", "A" },
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()

	local orderedKeys: { string }?, resolveReason: string? = ControllerRegistry.ResolveOrder({ "A", "B" })

	expect(resolveReason).toBeNil()
	expect(orderedKeys).toEqual({ "A", "B" })

	ControllerRegistry._ResetForTests()
end)
