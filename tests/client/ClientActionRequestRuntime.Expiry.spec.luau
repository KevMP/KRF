--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture, Utils.policies())
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("reclaims follow-up-free Unknown originals after grace and admits beyond the receipt bound", function()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 80 do
		local original: number = assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
		fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
		expect(requests:GetOriginalStart(original) ~= nil).toBe(true)
		fixture.clock.Advance(Constants.GRACE_SECONDS - 0.5)
		expect(requests:_GetRetainedCountForTests()).toBe(1)
		fixture.clock.Advance(0.5)
		expect(requests:GetOriginalStart(original)).toBeNil()
		expect(requests:_GetRetainedCountForTests()).toBe(0)
	end

	local nextOriginal: number?, reason: string? = Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 2 })
	expect(reason).toBeNil()
	expect(nextOriginal).toBe(81)
end)

it("reclaims retired automatic originals and Unknown follow-ups through repeated grace expiry", function()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })

	for _ = 1, 70 do
		Utils.tap(fixture)
		expect(requests:_GetRetainedCountForTests()).toBe(2)
		fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
		expect(requests:_GetRetainedCountForTests()).toBe(1)
		fixture.clock.Advance(Constants.GRACE_SECONDS)
		expect(requests:_GetRetainedCountForTests()).toBe(0)
	end

	expect(#Utils.packets(fixture)).toBe(140)
end)

it("preserves indefinite follow-up authority after Unknown correlation expires", function()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Combat.Rasengan", { aim = 1 }))
	local admission: RequestTypes.ActionRequestAdmission = assert(requests:GetOriginalStart(original))
	local statuses: { string } = {}

	requests:ObserveOutcomes(function(outcome): ()
		table.insert(statuses, outcome.status)
	end)

	fixture.clock.Advance(Constants.TIMEOUT_SECONDS + Constants.GRACE_SECONDS + 1000)
	expect(requests:GetOriginalStart(original)).toBe(admission)
	-- The transport no longer recognizes this result after grace; it cannot
	-- invent acceptance or resurrect correlation, even though follow-up authority remains.
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	expect(statuses).toEqual({ "Unknown" })
	expect({ Runtime.RequestStop(original, { releaseAim = 7 }) }).toEqual({ 2 })
end)

it("keeps Unknown to late Accepted correlation during grace and cancels its expiry", function()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())
	local original: number = assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	local statuses: { string } = {}

	requests:ObserveOutcomes(function(outcome): ()
		table.insert(statuses, outcome.status)
	end)

	fixture.clock.Advance(Constants.TIMEOUT_SECONDS)
	fixture.clock.Advance(Constants.GRACE_SECONDS / 2)
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	expect(statuses).toEqual({ "Unknown", "Accepted" })
	expect(requests:_GetRetainedCountForTests()).toBe(0)
	fixture.clock.Advance(Constants.GRACE_SECONDS)
	expect(statuses).toEqual({ "Unknown", "Accepted" })
end)
