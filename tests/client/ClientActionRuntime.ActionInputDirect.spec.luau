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
local Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("provides direct convenience methods on the same frozen facade with stable not-ready denials", function()
	local direct: Utils.DirectRuntime = Utils.direct()
	expect(table.isfrozen(Runtime)).toBe(true)
	expect({ direct.RequestAction(fixture.actor, "Mode.Aura") }).toEqual({ nil, "ClientNotReady" })
	expect({ direct.RequestStop(1) }).toEqual({ nil, "ClientNotReady" })
	expect({ direct.RequestInterrupt(1, "FocusLost") }).toEqual({ nil, "ClientNotReady" })
end)

it(
	"sends explicit full direct payloads through I5 without sampling input producers or fabricating an input session",
	function()
		local calls: number = 0

		local policies: Types.ActionInputPolicies = Utils.policies()

		policies["Combat.Rasengan"].startParameters = function(): any
			calls += 1

			return { aim = 99 }
		end

		policies["Combat.Rasengan"].stopParameters = function(): any
			calls += 1

			return { releaseAim = 99 }
		end

		Utils.ready(fixture, policies)
		local admissions: { RequestTypes.ActionRequestAdmission } = {}

		assert(Requests.Get()):ObserveAdmissions(function(admission): ()
			table.insert(admissions, admission)
		end)

		local direct: Utils.DirectRuntime = Utils.direct()
		local original: number?, reason: string? = direct.RequestAction(fixture.actor, "Combat.Rasengan", { aim = 8 })
		expect(reason).toBeNil()
		expect(original).toBe(1)
		assert(original ~= nil, "A direct caller must receive its locally admitted original ID")
		Utils.tap(fixture)
		expect({ direct.RequestStop(original, { releaseAim = 9 }) }).toEqual({ 2 })
		expect(calls).toBe(0)
		expect(Utils.packets(fixture)[1].parameters).toEqual({ aim = 8 })

		expect(Utils.packets(fixture)[2]).toMatchObject({
			kind = "KRF.Action.Stop",
			originalStartRequestId = original,
			parameters = { releaseAim = 9 },
		})

		expect(#admissions).toBe(2)

		for _, admission: RequestTypes.ActionRequestAdmission in admissions do
			expect(admission.origin).toBe("Direct")
			expect(admission.actor).toBe(fixture.actor)
			expect(admission.inputTimestamp).toBeNil()
		end
	end
)

it("returns typed Stop failure directly without sampling an input callback or automatically interrupting", function()
	Utils.ready(fixture, Utils.policies())
	local direct: Utils.DirectRuntime = Utils.direct()
	local original: number = assert(direct.RequestAction(fixture.actor, "Combat.Rasengan", { aim = 1 }))
	expect({ direct.RequestStop(original) }).toEqual({ nil, "ActionPayloadInvalid" })
	expect(#Utils.packets(fixture)).toBe(1)
	expect({ direct.RequestStop(original, { releaseAim = 5 }) }).toEqual({ 2 })
end)

it("keeps the original Actor in direct Interrupt metadata after the controlled Actor changes", function()
	Utils.ready(fixture, Utils.policies())
	local direct: Utils.DirectRuntime = Utils.direct()
	local original: number = assert(direct.RequestAction(fixture.actor, "Movement.Sprint"))
	local observed: RequestTypes.ActionRequestAdmission? = nil

	assert(Requests.Get()):ObserveAdmissions(function(admission): ()
		observed = admission
	end)

	expect({ Runtime.SetControlledActor(fixture.other) }).toEqual({ true })
	expect({ direct.RequestInterrupt(original, "ActorSwitched") }).toEqual({ 2 })
	expect(assert(observed).actor).toBe(fixture.actor)
	expect(assert(observed).originalStartRequestId).toBe(original)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Interrupt", originalStartRequestId = original })
end)

for _, followUp: string in { "Stop", "Interrupt" } do
	it(
		"suppresses automatic release after locally admitted direct " .. followUp .. " for an input-owned original",
		function()
			Utils.ready(fixture, Utils.policies())
			Utils.set(fixture, { Utils.route("Combat.Rasengan") })
			Utils.emit(fixture, "Pressed")
			-- Test-only private I5 correlation; no public automatic-activation enumeration.
			local original: number = Utils.started(fixture)
			local direct: Utils.DirectRuntime = Utils.direct()

			if followUp == "Stop" then
				expect({ direct.RequestStop(original, { releaseAim = 6 }) }).toEqual({ 2 })
			else
				expect({ direct.RequestInterrupt(original, "FocusLost") }).toEqual({ 2 })
			end

			Utils.emit(fixture, "Released")
			expect(#Utils.packets(fixture)).toBe(2)
		end
	)
end

it("preserves automatic release when a direct typed Stop was refused before admission", function()
	Utils.ready(fixture, Utils.policies())
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	local direct: Utils.DirectRuntime = Utils.direct()
	expect({ direct.RequestStop(original, { releaseAim = "invalid" }) }).toEqual({ nil, "ActionPayloadInvalid" })
	Utils.emit(fixture, "Released")

	expect(Utils.packets(fixture)[2]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
		parameters = { releaseAim = 2 },
	})
end)

it(
	"rejects unknown Actions, unavailable ActorViews, unknown originals, and invalid payloads without dispatch",
	function()
		Utils.ready(fixture, Utils.policies())
		local direct: Utils.DirectRuntime = Utils.direct()

		expect({ direct.RequestAction(fixture.actor, "Game.Unregistered") }).toEqual({
			nil,
			"ActionRequestUnregistered",
		})

		expect({ direct.RequestAction(fixture.actor, "Combat.Fireball", { aim = 0 / 0 }) }).toEqual({
			nil,
			"ActionPayloadInvalid",
		})

		expect({ direct.RequestStop(999) }).toEqual({ nil, "ActionStartUnknown" })
		expect({ direct.RequestInterrupt(999, "FocusLost") }).toEqual({ nil, "ActionStartUnknown" })
		Registry.Remove(fixture.actor)
		expect({ direct.RequestAction(fixture.actor, "Movement.Sprint") }).toEqual({ nil, "ActorViewUnavailable" })
		expect(Utils.packets(fixture)).toEqual({})
	end
)

it("refuses a retired original after definitive Start rejection", function()
	Utils.ready(fixture, Utils.policies())
	local direct: Utils.DirectRuntime = Utils.direct()
	local original: number = assert(direct.RequestAction(fixture.actor, "Movement.Sprint"))
	Utils.outcome(fixture, original, "KRF.Action.Start", "Rejected", "ActionNotGranted")
	expect({ direct.RequestStop(original) }).toEqual({ nil, "ActionStartUnknown" })
	expect(#Utils.packets(fixture)).toBe(1)
end)

it("does not carry old original IDs or captured native callbacks into a replacement client incarnation", function()
	Utils.ready(fixture, Utils.policies())
	local direct: Utils.DirectRuntime = Utils.direct()
	local original: number = assert(direct.RequestAction(fixture.actor, "Movement.Sprint"))
	local callback = assert(fixture.callbacks[fixture.actions.AbilitySlot1], "Expected the original native callback")
	Utils.destroy(fixture)
	fixture = Utils.new()
	Utils.ready(fixture, Utils.policies())
	callback("Released", false)
	expect({ direct.RequestStop(original) }).toEqual({ nil, "ActionStartUnknown" })
	expect(Utils.packets(fixture)).toEqual({})
end)

it("reclaims completed automatic OneShots without retaining input lifecycle records or timers", function()
	Utils.ready(fixture, Utils.policies())
	Utils.set(fixture, { Utils.route("Combat.Fireball") })
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for index: number = 1, 160 do
		Utils.tap(fixture)
		local packet: Utils.Packet? = Utils.packets(fixture)[index]
		expect(packet ~= nil).toBe(true)
		expect(packet).toMatchObject({ kind = "KRF.Action.Start", actionId = "Combat.Fireball" })
		Utils.outcome(fixture, assert(packet).requestId, "KRF.Action.Start", "Accepted")
		fixture.clock.Advance(1.01)
		expect(requests:_GetRetainedCountForTests()).toBe(0)
		expect(fixture.clock.Count()).toBe(0)
	end
end)

it("keeps a held original beyond result-history expiry without polling or a mandatory heartbeat", function()
	Utils.ready(fixture, Utils.policies())
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	local original: number = Utils.started(fixture)
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	expect(fixture.clock.Count()).toBe(0)
	fixture.clock.Advance(60)
	expect(#Utils.packets(fixture)).toBe(1)
	expect(fixture.clock.Count()).toBe(0)
	Utils.emit(fixture, "Released")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
end)

it("makes terminal teardown idempotent and prevents old native release from dispatching", function()
	Utils.ready(fixture, Utils.policies())
	Utils.set(fixture, { Utils.route("Combat.Rasengan") })
	Utils.emit(fixture, "Pressed")
	Utils.started(fixture)
	local callback = assert(fixture.callbacks[fixture.actions.AbilitySlot1], "Expected the original native callback")
	Client._ResetForTests()
	Client._ResetForTests()
	local count: number = #fixture.commands.sent
	callback("Released", false)
	fixture.clock.Advance(60)
	expect(#fixture.commands.sent).toBe(count)
	expect(next(fixture.callbacks)).toBeNil()
end)
