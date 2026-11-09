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
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Inputs: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Controls = require(KRF.client.Controls.ClientControls)
local ControlState = require(KRF.client.Controls.utils.ControlRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Installation = require(KRF.client.Action.utils.ActionObservationInstallation)
local ProtocolConstants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Commands = require(script.Parent.Utils.CommandClientTestUtils)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture
local capture: Utils.Capture?
local disconnects: { () -> () }

beforeEach(function()
	fixture = Input.new()
	capture = nil
	disconnects = {}
end)

afterEach(function()
	for _, disconnect in disconnects do
		disconnect()
	end

	if capture ~= nil then
		capture.disconnect()
	end

	Input.destroy(fixture)
end)

local function ready(): Utils.Capture
	Input.ready(fixture, Input.policies())
	local facts: Utils.Capture = Utils.capture()
	capture = facts

	return facts
end

for _, path: string in { "Controls", "PrivateControls", "Input", "PrivateInput", "PrivateRequests" } do
	it(
		"quarantines synchronous private observer reentry through " .. path .. " while preserving the admitted work",
		function()
			local facts: Utils.Capture = ready()
			Input.set(fixture, { Input.route("Combat.Rasengan") })
			Input.emit(fixture, "Pressed")
			local calls: number = 0
			local mutation: { any } = {}

			table.insert(
				disconnects,
				State.ObserveActionRequest(function(): ()
					calls += 1

					if calls ~= 1 then
						return
					end

					if path == "Controls" then
						mutation = { Controls.Apply({ contexts = { { contextId = "Combat", enabled = false } } }) }
					elseif path == "PrivateControls" then
						mutation = {
							assert(ControlState.Get(), "Expected controls owner").Apply({
								contexts = { { contextId = "Combat", enabled = false } },
							}),
						}
					elseif path == "Input" then
						mutation = { Inputs.SetContextEnabled("Combat", false) }
					elseif path == "PrivateInput" then
						mutation = { fixture.input.SetContextEnabled("Combat", false) }
					else
						mutation = {
							assert(Requests.Get(), "Expected request owner"):Start(
								{ actor = fixture.other, actionId = "Combat.Fireball", origin = "Direct" },
								{ aim = 4 }
							),
						}
					end
				end)
			)

			expect({ Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 3 }) }).toEqual({ 2 })
			expect(mutation).toEqual(if path == "PrivateRequests" then { 3 } else { true })
			expect({ Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 5 }) }).toEqual({ 4 })
			expect(calls).toBe(1)
			expect(#fixture.commands.sent).toBe(4)

			if path ~= "PrivateRequests" then
				expect(Utils.kinds(facts.private)).toEqual({
					"RequestAdmitted:Start",
					"RequestAdmitted:Start",
					"InvalidatedInterrupt",
					"RequestAdmitted:Interrupt",
					"RequestAdmitted:Start",
				})
			end

			Utils.parity(facts)
		end
	)
end

it("does not treat separately spawned downstream work as synchronous private observer reentry", function()
	ready()
	local calls: number = 0
	local scheduled: boolean = false

	table.insert(
		disconnects,
		State.ObserveActionRequest(function(): ()
			calls += 1

			if calls == 1 then
				task.spawn(function(): ()
					Runtime.RequestAction(fixture.other, "Combat.Fireball", { aim = 4 })
					scheduled = true
				end)
			end
		end)
	)

	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	task.wait()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 2 }))
	expect(scheduled).toBe(true)
	expect(#fixture.commands.sent).toBe(3)
	expect(calls).toBe(3)
end)

it("disconnects public listeners from an unconfigured incarnation before a configured reconnect", function()
	Commands.ready(fixture.commands)
	fixture.restore()
	expect(Requests.Get()).toBeNil()
	local oldCalls: number = 0

	local oldConnection = Runtime.OnActionRequest:Connect(function(): ()
		oldCalls += 1
	end)

	table.insert(disconnects, function(): ()
		oldConnection:Disconnect()
	end)

	Input.destroy(fixture)
	fixture = Input.new()
	local facts: Utils.Capture = ready()
	assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
	Utils.parity(facts)
	expect(#facts.public).toBe(1)
	expect(oldCalls).toBe(0)
end)

it("does not adopt a previous input owner while the new observation lifetime awaits startup", function()
	ready()
	Input.set(fixture, { Input.route("Combat.Rasengan") })
	Input.emit(fixture, "Pressed")
	local stop = Installation.Install(fixture.clock.Now)
	table.insert(disconnects, stop)
	local facts: { Types.ActionRequestEvent } = {}

	table.insert(
		disconnects,
		State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
			table.insert(facts, fact)
		end)
	)

	Input.emit(fixture, "Released")
	expect(facts).toEqual({})

	expect(Input.packets(fixture)).toMatchObject({
		{ kind = "KRF.Action.Start", requestId = 1 },
		{ kind = "KRF.Action.Stop", requestId = 2, originalStartRequestId = 1 },
	})
end)

for _, startup: string in { "InvalidPolicy", "HandshakeTimeout" } do
	it(
		"disconnects public listeners after " .. startup .. " before any input or request owner was installed",
		function()
			local oldCalls: number = 0

			local oldConnection = Runtime.OnActionRequest:Connect(function(): ()
				oldCalls += 1
			end)

			table.insert(disconnects, function(): ()
				oldConnection:Disconnect()
			end)

			if startup == "InvalidPolicy" then
				Commands.start(fixture.commands, { actionInputPolicies = { Missing = {} } })

				expect(fixture.commands.client.result).toEqual({
					success = false,
					failure = { system = "ActionInput", reason = "ActionInputPolicyUnknownAction" },
				})
			else
				Commands.start(fixture.commands)
				fixture.clock.Advance(ProtocolConstants.INIT_TIMEOUT_SECONDS)

				expect(fixture.commands.client.result).toEqual({
					success = false,
					failure = { system = "Networking", reason = "HandshakeTimeout" },
				})
			end

			expect(Requests.Get()).toBeNil()
			local lateCalls: number = 0

			local lateConnection = Runtime.OnActionRequest:Connect(function(): ()
				lateCalls += 1
			end)

			table.insert(disconnects, function(): ()
				lateConnection:Disconnect()
			end)

			Input.destroy(fixture)
			fixture = Input.new()
			local facts: Utils.Capture = ready()
			assert(Runtime.RequestAction(fixture.actor, "Combat.Fireball", { aim = 1 }))
			Utils.parity(facts)
			expect(#facts.public).toBe(1)
			expect(oldCalls).toBe(0)
			expect(lateCalls).toBe(0)
		end
	)
end
