--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local Selection = require(KRF.client.Action.utils.ActionInputSelection)
local Activations = require(KRF.client.Action.utils.ActionInputActivations)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture
local selected: Types.ActionRouteSelection
local store: Activations.Owner
local options: Selection.Options
local port: Types.ActionInputRoutePort?
local sends: number
local faults: { string }

beforeEach(function()
	fixture = Utils.new()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	selected = fixture.selections[1]
	store = Activations.new()
	sends = 0
	faults = {}

	port = {
		GetControlledActor = fixture.owner.GetControlledActor,
		GetEffectiveRoute = fixture.owner.GetEffectiveRoute,
		ObserveRoutes = fixture.owner.ObserveRoutes,
	}

	local oneShot: Types.CompiledActionInputPolicy = { activation = "OneShot", onInvalidation = "Keep" }

	options = {
		Policies = { ["Combat.Punch"] = oneShot },
		CanDispatch = function(): boolean
			return fixture.ready
		end,
		GetRoutes = function(): Types.ActionInputRoutePort?
			return port
		end,
		IsPressEpochActive = fixture.input.input.owner.IsPressEpochActive,
		Start = function(): (number?, string?)
			sends += 1

			return 1, nil
		end,
		Retire = function() end,
		Store = { Add = store.Add, Bind = store.Bind, Remove = store.Remove, FindToggle = store.FindToggle },
		ToggleOff = function() end,
		Flush = function() end,
		Report = function(reason: string): ()
			table.insert(faults, reason)
		end,
	}
end)

afterEach(function()
	store.Destroy()
	Utils.destroy(fixture)
end)

it("drops selections after detachment, Actor replacement, route retirement or readiness loss", function()
	local dispatch = Selection.new(options)
	local attached: Types.ActionInputRoutePort = assert(port, "Expected attached route port")
	port = nil
	dispatch(selected)
	port = attached
	Utils.select(fixture, fixture.other)
	dispatch(selected)
	Utils.select(fixture)
	fixture.owner.RemoveProfileSource(fixture.actor, "Base")
	dispatch(selected)
	fixture.ready = false
	dispatch(selected)
	expect(sends).toBe(0)
	expect(store.HasActive()).toBe(false)

	expect(faults).toEqual({
		"ActionInputOccurrenceIneligible",
		"ActionInputOccurrenceIneligible",
		"ActionInputOccurrenceIneligible",
	})
end)

it("rechecks route continuity after a producer and never falls back to another Action", function()
	options.Policies["Combat.Punch"] = {
		activation = "OneShot",
		onInvalidation = "Keep",
		startParameters = function(): any
			fixture.owner.RemoveProfileSource(fixture.actor, "Base")

			return { aim = 1 }
		end,
	}

	Selection.new(options)(selected)
	expect(sends).toBe(0)
	expect(faults).toEqual({ "ActionInputOccurrenceIneligible" })
end)

it("refuses automatic ownership pressure before Start and leaves no provisional activation", function()
	options.Policies["Combat.Punch"] = { activation = "Toggle", onInvalidation = "Keep" }

	options.Store.Add = function(): Activations.Record?
		return nil
	end

	Selection.new(options)(selected)
	expect(sends).toBe(0)
	expect(store.HasActive()).toBe(false)
	expect(faults).toEqual({ "ActionInputCapacityReached" })
end)
