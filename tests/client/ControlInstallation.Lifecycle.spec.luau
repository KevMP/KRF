--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local ActionTypes = require(KRF.client.Action.types)
local State = require(KRF.client.Controls.utils.ControlRuntimeState)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Owner = require(KRF.client.Controls.ControlOwner)
local Installation = require(KRF.client.Controls.utils.ControlInstallation)
local Native = require(KRF.client.Controls.utils.NativeControlLifecycle)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture
local installedStop: (() -> ())? = nil
local originalInstall = Installation.Install

beforeEach(function()
	fixture = Utils.new()
	installedStop = nil

	Installation.Install = function(isReady: () -> boolean): () -> ()
		local stop: () -> () = originalInstall(isReady)
		installedStop = stop

		return stop
	end
end)

afterEach(function()
	Installation.Install = originalInstall
	Utils.destroy(fixture)
end)

it("disconnects an installed lifetime exactly once and suppresses its retained native callback", function()
	Utils.ready(fixture)
	local stop: () -> () = assert(installedStop, "Expected normal control installation")
	expect(fixture.connections).toBe(1)
	stop()
	stop()
	expect(fixture.connections).toBe(0)
	fixture.lifecycle[1]({ kind = "FocusLost" })
	expect(fixture.base.input.GetContext("Combat")).toMatchObject({ enabled = true })
	expect(State.Get()).toBeNil()
end)

it("does not erase a replacement lifetime when an older cleanup finishes", function()
	Utils.ready(fixture)
	local stop: () -> () = assert(installedStop, "Expected normal control installation")
	local actions: ActionTypes.ClientActionOwner = assert(ActionState.Get(), "Expected Action owner")

	local replacement: Types.ControlOwner = Owner.new(fixture.base.input, actions, function(): boolean
		return true
	end)

	State.Install(replacement)
	stop()
	expect(State.Get() == replacement).toBe(true)
	replacement.Destroy()
	State.Install(nil)
end)

it("ignores platform callbacks until READY rather than retiring inputs during startup", function()
	local observe = Native.Observe

	Native.Observe = function(callback, signals): () -> ()
		local stop: () -> () = observe(callback, signals)
		callback({ kind = "FocusLost" })

		return stop
	end

	Utils.ready(fixture)
	Utils.charge(fixture)
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
	ActionUtils.emit(fixture.base, "Released")
	expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start", "KRF.Action.Stop" })
end)
