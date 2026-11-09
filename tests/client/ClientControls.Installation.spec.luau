--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("exports only a stable frozen Apply facade with no mutable owners or public transaction handles", function()
	expect(table.isfrozen(Controls)).toBe(true)
	local fields: { string } = {}

	for key in (Controls :: unknown) :: { [string]: unknown } do
		table.insert(fields, key)
	end

	expect(fields).toEqual({ "Apply" })
	expect({ Controls.Apply({}) }).toEqual({ false, "ClientNotReady" })
end)

it("installs through normal READY startup without requiring a coordinator config option", function()
	expect({ Controls.Apply({}) }).toEqual({ false, "ClientNotReady" })
	Utils.ready(fixture)
	Utils.apply({})
	expect(fixture.connections).toBe(1)
	expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
end)

it("does not install lifecycle listeners before READY and disconnects them exactly once on reset", function()
	expect(fixture.connections).toBe(0)
	Utils.ready(fixture)
	expect(fixture.connections).toBe(1)
	Client._ResetForTests()
	Client._ResetForTests()
	expect(fixture.connections).toBe(0)
	expect({ Controls.Apply({}) }).toEqual({ false, "ClientNotReady" })
	expect(fixture.base.callbacks).toEqual({})
end)

it(
	"keeps the same facade across owner generations and prevents old lifecycle callbacks from mutating new owners",
	function()
		Utils.ready(fixture)
		expect(#fixture.lifecycle).toBe(1)
		local stale: (Types.ControlLifecycleEvent) -> () = fixture.lifecycle[1]
		Utils.destroy(fixture)
		fixture = Utils.new()
		Utils.ready(fixture)
		Utils.charge(fixture)
		stale({ kind = "FocusLost" })
		Utils.apply({})
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
		expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
		expect(fixture.connections).toBe(1)
	end
)
