--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Commands = require(KRF.client.Networking.utils.CommandRuntimeState)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture
local capture: Utils.Capture
local disconnects: { () -> () }

beforeEach(function()
	fixture = Input.new()
	disconnects = {}
end)

afterEach(function()
	for _, disconnect in disconnects do
		disconnect()
	end

	Input.destroy(fixture)
end)

local function ready(policies: Types.ActionInputPolicies?): ()
	Input.ready(fixture, policies or Input.policies())
	capture = Utils.capture()
	table.insert(disconnects, capture.disconnect)
end

it("finishes physical egress before same-stack private work and stages an immediate reply behind admission", function()
	local order: { string } = {}
	local sending: boolean = false
	local enabled: boolean = false
	local send = fixture.commands.client.transport.SendReliable

	fixture.commands.client.transport.SendReliable = function(payload: buffer): ()
		if not enabled then
			send(payload)

			return
		end

		sending = true
		table.insert(order, "Send")
		send(payload)
		Utils.result(fixture, 1, "Start", "Accepted", 89)
		table.insert(order, "SendReturned")
		sending = false
	end

	ready()
	enabled = true

	table.insert(
		disconnects,
		State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
			expect(sending).toBe(false)
			table.insert(order, fact.kind)
		end)
	)

	expect({ Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }) }).toEqual({ 1 })
	expect(order).toEqual({ "Send", "SendReturned", "RequestAdmitted", "RequestOutcome" })
	expect(#capture.private).toBe(2)
	expect(capture.private[1].eventOrdinal < capture.private[2].eventOrdinal).toBe(true)
	Utils.parity(capture)
end)

it("reports admitted then Unknown when the local physical send throws without retrying", function()
	local attempts: number = 0
	local enabled: boolean = false
	local send = fixture.commands.client.transport.SendReliable

	fixture.commands.client.transport.SendReliable = function(payload: buffer): ()
		if not enabled then
			send(payload)

			return
		end

		attempts += 1
		error("InjectedSendFault", 0)
	end

	ready()
	enabled = true

	expect({ Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }) }).toEqual({ 1 })
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestOutcome:Start" })
	expect(Utils.fact(capture.private, 2)).toMatchObject({ status = "Unknown", requestId = 1 })
	expect(attempts).toBe(1)
	Utils.parity(capture)
end)

it("serializes release during Start egress as Start admission, genuine release and admitted Stop", function()
	ready()
	Input.set(fixture, { Input.route("Combat.Rasengan") })

	fixture.commands.beforeSend = function(): ()
		fixture.commands.beforeSend = nil
		Input.emit(fixture, "Released")
	end

	Input.emit(fixture, "Pressed")
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "GenuineRelease", "RequestAdmitted:Stop" })
	expect(#Input.packets(fixture)).toBe(2)

	for index, fact: Types.ActionRequestEvent in capture.private do
		expect(fact.eventOrdinal).toBe(index)
		expect(fact.originalStartRequestId).toBe(1)
		expect(fact.originalStartKey).toBe(capture.private[1].originalStartKey)
	end

	Utils.parity(capture)
end)

for _, fault: string in { "Throw", "Yield", "Reenter" } do
	it("quarantines a private observer that attempts to " .. fault .. " after the packet has left", function()
		ready()
		local calls: number = 0
		local sentCounts: { number } = {}

		table.insert(
			disconnects,
			State.ObserveActionRequest(function(): ()
				calls += 1
				table.insert(sentCounts, #fixture.commands.sent)

				if fault == "Throw" then
					error("PresentationFault", 0)
				elseif fault == "Yield" then
					coroutine.yield()
				else
					Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 2 })
				end
			end)
		)

		assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
		local sentAfterFirst: number = #fixture.commands.sent
		assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 3 }))
		expect(calls).toBe(1)
		expect(sentCounts[1] > 0).toBe(true)
		expect(#fixture.commands.sent).toBe(sentAfterFirst + 1)
		expect(#capture.private).toBe(#fixture.commands.sent)
		Utils.parity(capture)
	end)
end

it("stages a release before I5 reservation until Start admission exists", function()
	ready()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	local commands: NetworkingTypes.ClientCommandRuntime = assert(Commands.Get(), "Expected command runtime")
	local send = commands._SendAdmitted

	commands._SendAdmitted = function(self, id, actor, parameters, admit, committed): (number?, string?)
		if id == "KRF.Action.Start" then
			Input.emit(fixture, "Released")
		end

		return send(self, id, actor, parameters, admit, committed)
	end

	Input.emit(fixture, "Pressed")
	expect(#Input.packets(fixture)).toBe(2)
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "GenuineRelease", "RequestAdmitted:Stop" })
	Utils.parity(capture)
end)

it("keeps nested admitted requests behind older serialized egress without duplicate observations", function()
	ready()
	local nested: number?
	local observedDuringSend: number = -1

	fixture.commands.beforeSend = function(): ()
		fixture.commands.beforeSend = nil
		nested = Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 2 })
		observedDuringSend = #capture.private
	end

	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	expect(nested).toBe(2)
	expect(observedDuringSend).toBe(0)
	expect(#Input.packets(fixture)).toBe(2)
	expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start", "RequestAdmitted:Start" })
	expect(Utils.fact(capture.private, 1)).toMatchObject({ actor = fixture.actor, requestId = 1, eventOrdinal = 1 })
	expect(Utils.fact(capture.private, 2)).toMatchObject({ actor = fixture.other, requestId = 2, eventOrdinal = 2 })
	Utils.parity(capture)
end)

for _, refusal: string in
	{
		"UnknownAction",
		"BadPayload",
		"ResolverNil",
		"ProducerThrows",
		"ProducerYields",
		"InactiveWhileDown",
		"PendingFull",
	}
do
	it("emits no ghost admission on " .. refusal .. " and still observes the next valid request", function()
		local policies: Types.ActionInputPolicies = Input.policies()

		if refusal == "ProducerThrows" or refusal == "ProducerYields" then
			policies["Combat.Rasengan"].startParameters = function(): any
				if refusal == "ProducerThrows" then
					error("AimMissing", 0)
				end

				coroutine.yield()

				return { aim = 1 }
			end
		end

		ready(policies)
		local commands: NetworkingTypes.ClientCommandRuntime = assert(Commands.Get())
		local send = commands._SendAdmitted

		if refusal == "PendingFull" then
			commands._SendAdmitted = function(): (number?, string?)
				return nil, "CommandPendingFull"
			end
		end

		if refusal == "UnknownAction" then
			expect({ Runtime.RequestAction(fixture.actor, "Missing") }).toEqual({ nil, "ActionRequestUnregistered" })
		elseif refusal == "BadPayload" then
			expect({ Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = "wrong" }) }).toEqual({
				nil,
				"ActionPayloadInvalid",
			})
		elseif refusal == "ResolverNil" then
			Input.set(fixture, {
				{
					when = Input.key(),
					target = {
						kind = "Dynamic",
						resolve = function(): Types.ResolvedAction?
							return nil
						end,
					},
				},
			})

			Input.tap(fixture)
		else
			if refusal == "InactiveWhileDown" then
				assert(
					fixture.input.SetSource(
						"Tap",
						{ gestures = { AbilitySlot1 = { Tap = { maxDurationSeconds = 0.25 } } } }
					)
				)
			end

			Input.set(fixture, {
				Input.route("Combat.Rasengan", if refusal == "InactiveWhileDown" then Input.key(nil, "Tap") else nil),
			})

			Input.tap(fixture)
		end

		expect(capture.private).toEqual({})
		Utils.parity(capture)
		expect(fixture.commands.sent).toEqual({})
		commands._SendAdmitted = send
		assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
		expect(Utils.kinds(capture.private)).toEqual({ "RequestAdmitted:Start" })
		Utils.parity(capture)
	end)
end
