--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local InputTypes = require(KRF.client.Input.types)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, offset: number in { 1, 2, 3 } do
	it("delegates native write fault " .. offset .. " to I1 restoration and safely rearms retired epochs", function()
		expect({ fixture.base.input.SetSource("Extra", { contexts = { Extra = { priority = 1, sink = false } } }) }).toEqual({
			true,
		})

		expect({ fixture.base.input.SetContextEnabled("Extra", true) }).toEqual({ true })
		Utils.charge(fixture)
		fixture.failAt[#fixture.writes + offset] = true

		expect({
			Controls.Apply({
				contexts = {
					{ contextId = "Combat", enabled = false },
					{ contextId = "Gate", enabled = false },
					{ contextId = "Extra", enabled = false },
				},
				selection = { kind = "Set", actor = fixture.base.other },
			}),
		}).toEqual({ false, "NativeCommitFailed" })

		expect(fixture.base.input.GetContext("Combat")).toMatchObject({ enabled = true })
		expect(fixture.base.input.GetContext("Gate")).toMatchObject({ enabled = true })
		expect(fixture.base.input.GetContext("Extra")).toMatchObject({ enabled = true })
		expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
		expect(fixture.stopCalls).toBe(0)
		local packets: number = #ActionUtils.packets(fixture.base)
		ActionUtils.emit(fixture.base, "Pressed")
		expect(#ActionUtils.packets(fixture.base)).toBe(packets)
		ActionUtils.emit(fixture.base, "Released")
		expect(fixture.stopCalls).toBe(0)
	end)
end

it("closes all affected owners exactly once when native application and restoration both fail", function()
	Utils.charge(fixture)
	local cancelled: number = 0

	local stop = fixture.base.input.ObservePrimitive("Routing", function(occurrence): ()
		if occurrence.event.kind == "Cancelled" then
			cancelled += 1
		end
	end)

	fixture.onWrite = function(operation: string): ()
		if operation == "ConfigureContext:Combat" then
			local context: InputContext = fixture.base.actions.AbilitySlot1.Parent :: InputContext
			context.Enabled = false
			error("UnrestorableNativeWrite", 0)
		end
	end

	expect({
		Controls.Apply({
			contexts = { { contextId = "Combat", enabled = false } },
			selection = { kind = "Set", actor = fixture.base.other },
		}),
	}).toEqual({ false, "InputRuntimeFaulted" })

	fixture.onWrite = nil
	expect(Runtime.GetControlledActor()).toBeNil()
	expect(fixture.base.input.GetInput("AbilitySlot1")).toBeNil()
	expect(Runtime.GetProfileSources(fixture.base.actor)).toEqual({})
	expect(#fixture.base.container:GetDescendants()).toBe(0)
	expect(fixture.base.callbacks).toEqual({})
	expect(cancelled).toBe(1)
	expect(fixture.stopCalls).toBe(0)
	expect({ Controls.Apply({}) }).toEqual({ false, "InputRuntimeFaulted" })
	stop()
end)

it(
	"fails closed on a mandatory private observer fault after publication rather than restoring partial owners",
	function()
		Utils.charge(fixture)

		local stop = fixture.base.input.ObserveConfigurationCommit(function(): ()
			error("MandatoryObserverFault", 0)
		end)

		local ok: boolean, reason: string? =
			Controls.Apply({ contexts = { { contextId = "Combat", enabled = false } } })

		expect({ ok, reason }).toEqual({ false, "InputRuntimeFaulted" })
		expect(Runtime.GetControlledActor()).toBeNil()
		expect(fixture.base.callbacks).toEqual({})
		expect(fixture.stopCalls).toBe(0)
		expect(#ActionUtils.packets(fixture.base) <= 2).toBe(true)
		stop()
	end
)

it("performs no IAS writes or activation retirement for deterministic final graph rejection", function()
	local original: number = Utils.charge(fixture)
	local graph: InputTypes.InputGraphSnapshot = fixture.base.input.GetGraphSnapshot()
	local writes: number = #fixture.writes

	expect({ Controls.Apply({ inputs = { { kind = "Remove", sourceId = "Core" } } }) }).toEqual({
		false,
		"ProfileDependencyMissing",
	})

	expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
	expect(#fixture.writes).toBe(writes)
	expect(fixture.stopCalls).toBe(0)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	ActionUtils.emit(fixture.base, "Released")

	expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
	})
end)
