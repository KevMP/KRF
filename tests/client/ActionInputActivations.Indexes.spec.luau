--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Activations = require(KRF.client.Action.utils.ActionInputActivations)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture
local store: Activations.Owner
local selected: Types.ActionRouteSelection

local policy: Types.CompiledActionInputPolicy =
	table.freeze({ activation = "WhileDown" :: "WhileDown", onInvalidation = "Interrupt" :: "Interrupt" })

local toggle: Types.CompiledActionInputPolicy =
	table.freeze({ activation = "Toggle" :: "Toggle", onInvalidation = "Keep" :: "Keep" })

beforeEach(function()
	fixture = Utils.new()
	store = Activations.new()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	selected = fixture.selections[1]
end)

afterEach(function()
	store.Destroy()
	Utils.destroy(fixture)
end)

local function admission(id: number, actionId: string?): RequestTypes.ActionRequestAdmission
	local value: RequestTypes.ActionRequestAdmission = {
		kind = "Start",
		incarnation = 1,
		requestId = id,
		originalStartRequestId = id,
		actor = selected.actor,
		actionId = actionId or selected.actionId,
		origin = "Input",
		requestKey = "fixture:" .. id,
		originalStartKey = "fixture:" .. id,
	}

	return table.freeze(value)
end

local function selection(
	actionId: string,
	key: Types.RouteKey,
	hold: InputTypes.RecognitionHoldOwner?
): Types.ActionRouteSelection
	return {
		actor = selected.actor,
		actorId = selected.actorId,
		sourceId = selected.sourceId,
		routeVersion = selected.routeVersion,
		selectionGeneration = selected.selectionGeneration,
		key = key,
		actionId = actionId,
		envelope = selected.envelope,
		candidate = selected.candidate,
		holdOwner = hold,
	}
end

it("releases all independent routes on the same exact epoch without consuming another generation", function()
	local other: Types.ActionRouteSelection =
		selection(selected.actionId, { kind = "Sequence", sequenceId = "Cast" }, selected.holdOwner)

	local first: Activations.Record = assert(store.Add(selected, policy))
	local second: Activations.Record = assert(store.Add(other, policy))
	local occurrence: InputTypes.PrimitiveOccurrence?

	fixture.input.input.owner.ObservePrimitive("Interpretation", function(value): ()
		if value.event.kind == "Released" then
			occurrence = value
		end
	end)

	Utils.emit(fixture, 0.1, "X", "Released")
	local released: InputTypes.PrimitiveOccurrence = assert(occurrence, "Expected genuine release")
	expect(#store.ByEpoch(released)).toBe(2)

	local stale: InputTypes.PrimitiveOccurrence =
		{ event = released.event, generation = released.generation + 1, pressEpochId = released.pressEpochId }

	expect(store.ByEpoch(stale)).toEqual({})
	store.ConsumeEpoch(first)
	expect(store.ByEpoch(released)).toEqual({ second })
	store.Remove(first)
	store.Remove(second)
	expect(store.ByEpoch(released)).toEqual({})
	expect(store.HasActive()).toBe(false)
end)

it("keeps same-route Toggles distinct by concrete Action and refuses duplicate identity", function()
	local first: Activations.Record = assert(store.Add(selected, toggle))
	local other: Types.ActionRouteSelection = selection("Other.Action", selected.key, selected.holdOwner)
	local second: Activations.Record = assert(store.Add(other, toggle))
	expect(store.Add(selected, toggle)).toBeNil()
	expect(store.FindToggle(selected)).toBe(first)
	expect(store.FindToggle(other)).toBe(second)
	expect(#store.ByRoute(selected.actor, selected.key)).toBe(2)
	store.Remove(first)
	expect(store.ByRoute(selected.actor, selected.key)).toEqual({ second })
	expect(store.FindToggle(selected)).toBeNil()
	expect(store.ByActor(nil)).toEqual({})
	store.Remove(second)
	expect(store.ByActor(selected.actor)).toEqual({})
end)

it("allows ownerless Toggle and late correlation without resurrecting retired indexes", function()
	local ownerless: Types.ActionRouteSelection = selection(selected.actionId, selected.key, nil)
	local record: Activations.Record = assert(store.Add(ownerless, toggle))
	store.Remove(record)
	store.Bind(record, admission(1))
	expect(record.admission).toEqual(admission(1))
	expect(store.ByRequest(1)).toBeNil()
	expect(store.FindToggle(ownerless)).toBeNil()
	store.Remove(record)
	expect(store.HasActive()).toBe(false)
end)

it("caps live ownership at 64 and reclaims capacity and request indexes on retirement", function()
	local records: { Activations.Record } = {}

	for index = 1, 64 do
		local candidate: Types.ActionRouteSelection = selection("Action" .. index, selected.key, selected.holdOwner)
		local record: Activations.Record = assert(store.Add(candidate, toggle))
		store.Bind(record, admission(index, candidate.actionId))
		table.insert(records, record)
	end

	local revision: number = store.Revision()
	expect(store.Add(selected, toggle)).toBeNil()
	expect(store.Revision()).toBe(revision)
	store.Remove(records[1])
	expect(store.ByRequest(1)).toBeNil()
	expect(store.Add(selected, toggle) ~= nil).toBe(true)
	expect(#store.ByActor(selected.actor)).toBe(64)
	store.Destroy()
	store.Destroy()
	expect(store.ByRoute(selected.actor, selected.key)).toEqual({})
	expect(store.HasActive()).toBe(false)
end)
