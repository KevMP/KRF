--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("validates an immutable prospective graph before any native write", function()
	local seen: Types.InputGraphSnapshot? = nil

	fixture.owner.RegisterGraphValidator(function(graph: Types.InputGraphSnapshot): (boolean, string?)
		expect(#fixture.writes).toBe(0)
		expect(fixture.owner.GetInput("Primary")).toBeNil()
		expect(table.isfrozen(graph)).toBe(true)
		expect(table.isfrozen(graph.inputs)).toBe(true)
		expect(graph.inputs.Primary.sourceId).toBe("Core")
		expect(graph.contexts.Gameplay.enabled).toBe(false)
		expect(graph.bindings.Primary.Keyboard.definition.keyCode).toBe(Enum.KeyCode.Q)
		seen = graph

		return true, nil
	end)

	TestUtils.install(fixture)
	expect(seen).never.toBeNil()
end)

it("rejects profile dependencies even when the dependent Actor or route is not active", function()
	TestUtils.install(fixture)

	local stop: () -> () = fixture.owner.RegisterGraphValidator(
		function(graph: Types.InputGraphSnapshot): (boolean, string?)
			if graph.inputs.Primary == nil then
				return false, "ReferencedByControlProfile"
			end

			return true, nil
		end
	)

	local before: number = #fixture.writes
	expect({ fixture.owner.RemoveSource("Core") }).toEqual({ false, "ReferencedByControlProfile" })
	expect(#fixture.writes).toBe(before)
	expect((assert(fixture.owner.GetInput("Primary"), "Expected installed input")).sourceId).toBe("Core")
	stop()
	expect(fixture.owner.RemoveSource("Core")).toBe(true)
end)

it("rejects a validator throw before native mutation", function()
	fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		error("ValidatorFailure")
	end)

	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "InputGraphValidatorFailed" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects a validator yield before native mutation", function()
	fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		coroutine.yield()

		return true, nil
	end)

	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "InputGraphValidatorYielded" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects a validator malformed result before native mutation", function()
	fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		return "yes" :: any, nil
	end)

	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "InvalidGraphValidatorResult" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects source mutation from a prospective validator without reentering preflight", function()
	local nested: { any } = {}

	fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		nested = { fixture.owner.SetSource("Nested", {}) }

		return true, nil
	end)

	TestUtils.install(fixture)
	expect(nested).toEqual({ false, "InputMutationDuringValidation" })
end)

it("passes the opaque proposed profile snapshot during prepare and publishes only on commit", function()
	TestUtils.install(fixture)
	local proposed: any = table.freeze({ removeRoute = "Primary" })

	fixture.owner.RegisterGraphValidator(function(graph: Types.InputGraphSnapshot, profiles: any?): (boolean, string?)
		if graph.inputs.Primary == nil and profiles ~= proposed then
			return false, "ReferencedByControlProfile"
		end

		return true, nil
	end)

	local before: number = #fixture.writes
	local plan: Types.PreparedInputUpdate?, reason: string? = fixture.owner.PrepareSource("Core", nil, proposed)
	expect(reason).toBeNil()
	expect(plan).never.toBeNil()
	expect(#fixture.writes).toBe(before)
	expect(fixture.owner.GetInput("Primary")).never.toBeNil()
	assert(plan ~= nil, "Expected prepared input plan")
	expect(fixture.owner.CommitPrepared(plan)).toBe(true)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("notifies configuration gates synchronously even without a pressed input", function()
	TestUtils.install(fixture)
	local changes: { Types.InputGraphChange } = {}

	fixture.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange)
		expect((assert(fixture.owner.GetContext("Gameplay"), "Expected installed context")).enabled).toBe(
			change.next.contexts.Gameplay.enabled
		)

		expect(table.isfrozen(change)).toBe(true)
		expect(table.isfrozen(change.affectedContextIds)).toBe(true)
		table.insert(changes, change)
	end)

	TestUtils.enable(fixture)
	expect(#changes).toBe(1)
	expect(changes[1].previous.contexts.Gameplay.enabled).toBe(false)
	expect(changes[1].next.contexts.Gameplay.enabled).toBe(true)
	expect(changes[1].affectedContextIds).toEqual({ "Gameplay" })
	expect(changes[1].invalidatedEpochIds).toEqual({})
	expect(#fixture.events).toBe(0)
	expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	expect(#changes).toBe(2)
	expect(changes[2].generation > changes[1].generation).toBe(true)
end)

it("does not publish a configuration delta for an equivalent update or repeated enablement", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local changes: number = 0

	fixture.owner.ObserveConfigurationCommit(function()
		changes += 1
	end)

	expect(fixture.owner.SetSource("Core", TestUtils.definition())).toBe(true)
	TestUtils.enable(fixture)
	expect(changes).toBe(0)
end)

it("fences native callbacks during application until all changed state is coherent", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local committed: boolean = false

	fixture.owner.ObserveConfigurationCommit(function(change: Types.InputGraphChange)
		expect(change.next.bindings.Primary.Keyboard.definition.keyCode).toBe(Enum.KeyCode.E)
		committed = true
	end)

	fixture.owner.ObservePrimitive("Routing", function()
		expect(committed).toBe(true)

		expect(
			(assert(fixture.owner.GetEffectiveBindings("Primary"), "Expected effective bindings")).Keyboard.definition.keyCode
		).toBe(Enum.KeyCode.E)
	end)

	fixture.onWrite = function()
		TestUtils.emit(fixture, "Pressed", true)
	end

	expect(
		fixture.owner.SetSource(
			"Rebind",
			{ bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	).toBe(true)

	fixture.onWrite = nil
	expect(committed).toBe(true)
end)

it("fails closed when a mandatory configuration observer throws", function()
	TestUtils.install(fixture)

	fixture.owner.ObserveConfigurationCommit(function()
		error("SafetyFailure")
	end)

	expect({ fixture.owner.SetContextEnabled("Gameplay", true) }).toEqual({ false, "InputRuntimeFaulted" })
	expect({ fixture.owner.SetSource("Later", {}) }).toEqual({ false, "InputRuntimeFaulted" })
	expect(#fixture.container:GetDescendants()).toBe(0)
	expect(fixture.connections).toBe(0)
end)

it("fails closed when a mandatory configuration observer yields", function()
	TestUtils.install(fixture)

	fixture.owner.ObserveConfigurationCommit(function()
		coroutine.yield()
	end)

	expect({ fixture.owner.SetContextEnabled("Gameplay", true) }).toEqual({ false, "InputRuntimeFaulted" })
	expect({ fixture.owner.SetSource("Later", {}) }).toEqual({ false, "InputRuntimeFaulted" })
	expect(#fixture.container:GetDescendants()).toBe(0)
	expect(fixture.connections).toBe(0)
end)
