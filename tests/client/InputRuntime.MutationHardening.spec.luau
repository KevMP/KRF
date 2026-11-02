--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Constants = require(KRF.client.Input.utils.InputConstants)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("serializes source replacement and context disable requested by a primitive observer", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local routingEnabled: boolean = false

	fixture.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind ~= "Pressed" then
			return
		end

		expect(fixture.owner.SetSource("Other", { contexts = { Menu = { priority = 3000, sink = true } } })).toBe(true)
		expect(fixture.owner.SetContextEnabled("Gameplay", false)).toBe(true)
	end)

	fixture.owner.ObservePrimitive("Routing", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind == "Pressed" then
			routingEnabled = assert(fixture.owner.GetContext("Gameplay"), "Expected context").enabled
		end
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(routingEnabled).toBe(true)
	expect(assert(fixture.owner.GetContext("Gameplay"), "Expected context").enabled).toBe(false)
	expect(assert(fixture.owner.GetContext("Menu"), "Expected queued context").enabled).toBe(false)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
end)

it("reports rejected queued changes and continues with later valid changes", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)

	fixture.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind ~= "Pressed" then
			return
		end

		fixture.owner.SetSource(
			"Broken",
			{ inputs = { Extra = { context = "Absent", type = Enum.InputActionType.Bool, bindings = {} } } }
		)

		fixture.owner.RemoveSource("")
		fixture.owner.SetContextEnabled("Gameplay", false)
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(fixture.faults).toEqual({ "UnknownContext" })
	expect(fixture.owner.GetInput("Extra")).toBeNil()
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Cancelled" })
	expect({ fixture.owner.RemoveSource("") }).toEqual({ false, "InvalidSourceId" })
end)

it("bounds reentrant mutation queues and retires each input once", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local overflow: { any } = {}

	fixture.owner.ObservePrimitive("Interpretation", function(occurrence: Types.PrimitiveOccurrence)
		if occurrence.event.kind ~= "Pressed" then
			return
		end

		for index: number = 1, Constants.MAX_PENDING_MUTATIONS do
			expect(fixture.owner.RemoveSource("Missing" .. index)).toBe(true)
		end

		overflow = { fixture.owner.RemoveSource("Core") }
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(overflow).toEqual({ false, "InputMutationQueueLimitExceeded" })
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed" })
	expect(fixture.owner.GetInput("Primary")).never.toBeNil()
end)

it("bounds a callback chain that keeps queuing new configuration commits", function()
	TestUtils.install(fixture)

	fixture.owner.ObserveConfigurationCommit(function()
		fixture.owner.SetContextEnabled(
			"Gameplay",
			not assert(fixture.owner.GetContext("Gameplay"), "Expected context").enabled
		)
	end)

	expect(fixture.owner.SetContextEnabled("Gameplay", true)).toBe(true)
	expect(fixture.faults).toEqual({ "InputMutationQueueLimitExceeded" })
	expect(fixture.owner.GetInput("Primary")).never.toBeNil()
end)

it("disconnects primitive observers before teardown can publish a stale event", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local routed: number = 0

	fixture.owner.ObservePrimitive("Interpretation", function()
		fixture.owner.Destroy()
	end)

	fixture.owner.ObservePrimitive("Routing", function()
		routed += 1
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(routed).toBe(0)
	expect(#fixture.events).toBe(0)
	expect(fixture.connections).toBe(0)
end)

it("aborts installation when client teardown occurs during prospective validation", function()
	fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		fixture.owner.Destroy()

		return true, nil
	end)

	expect({ fixture.owner.SetSource("Core", TestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	expect(#fixture.writes).toBe(0)
	expect(fixture.containerDestroyCalls).toBe(1)
end)

it("skips validator and commit observers disconnected earlier in the same phase", function()
	local stopValidator: () -> () = function() end
	local stopCommit: () -> () = function() end

	fixture.owner.RegisterGraphValidator(function()
		stopValidator()

		return true, nil
	end)

	stopValidator = fixture.owner.RegisterGraphValidator(function()
		error("DisconnectedValidator")
	end)

	fixture.owner.ObserveConfigurationCommit(function()
		stopCommit()
	end)

	stopCommit = fixture.owner.ObserveConfigurationCommit(function()
		error("DisconnectedSafetyObserver")
	end)

	TestUtils.install(fixture)
	expect(fixture.faults).toEqual({})
end)

it("contains publisher failures and nonfinite clock samples after committing the primitive", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	TestUtils.emit(fixture, "Pressed", true)
	fixture.now = 0 / 0

	fixture.onPublish = function(): ()
		error("PublisherFailure")
	end

	TestUtils.emit(fixture, "Released", false)
	expect(fixture.events[2].timestamp).toBe(10)
	expect(TestUtils.kinds(fixture)).toEqual({ "Pressed", "Released" })
	expect(#fixture.faults).toBe(1)
	fixture.onPublish = nil
	TestUtils.emit(fixture, "Pressed", true)

	fixture.onPublish = function(): ()
		error("PublisherFailure")
	end

	expect(fixture.owner.RemoveSource("Core")).toBe(true)
	expect(#fixture.faults).toBe(2)
	expect(fixture.owner.GetInput("Primary")).toBeNil()
end)

it("rejects malformed label references without altering an installed input", function()
	TestUtils.install(fixture)

	expect({ fixture.owner.BindActionLabel("Primary", fixture.container :: any) }).toEqual({
		false,
		"InvalidInputActionLabel",
	})

	expect({ fixture.owner.UnbindActionLabel(false :: any) }).toEqual({ false, "InvalidInputActionLabel" })
	expect(fixture.owner.GetInput("Primary")).never.toBeNil()
end)
