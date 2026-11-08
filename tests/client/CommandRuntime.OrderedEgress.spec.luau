--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local State = require(KRF.client.Networking.utils.CommandRuntimeState)
local CommandCodec: SharedTypes.CommandCodecModule = require(KRF.shared.Networking.CommandCodec)
local Client = require(KRF.client)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local fixture: TestUtils.Fixture
local clock = Clock.new()

beforeEach(function()
	fixture = TestUtils.new()
	clock = Clock.new(100)
	Native.Now = clock.Now
	Native.ScheduleTimeout = clock.Schedule
end)

afterEach(function()
	fixture.cleanup()
end)

local function runtime(): Types.ClientCommandRuntime
	TestUtils.ready(fixture)
	local installed: Types.ClientCommandRuntime? = State.Get()
	assert(installed ~= nil, "Expected the installed private command runtime")

	return installed
end

local function sentIds(): { number }
	local protocol: SharedTypes.ClientProtocol? = fixture.protocol
	assert(protocol ~= nil, "Expected the reconstructed protocol")
	local codec: SharedTypes.CommandCodec = CommandCodec.Compile(protocol)
	local ids: { number } = {}

	for _, payload: buffer in fixture.sent do
		local request: SharedTypes.CommandRequest? = codec.DecodeRequest(payload)
		assert(request ~= nil, "Expected a decodable command request")
		table.insert(ids, request.requestId)
	end

	return ids
end

it("consults admission with the allocated id before the packet is physically sent", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local seen: { any } = {}

	local requestId: number?, reason: string? = commands:_SendAdmitted(
		"Game.Ping",
		nil,
		nil,
		function(id: number): boolean
			table.insert(seen, { id = id, sent = #fixture.sent })

			return true
		end
	)

	expect(reason).toBeNil()
	expect(requestId).toBe(1)
	expect(seen).toEqual({ { id = 1, sent = 0 } })
	expect(sentIds()).toEqual({ 1 })
end)

it("rolls back a refused admission without sending, consuming the id or leaving a timer", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local timers: number = clock.Count()

	local requestId: number?, reason: string? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		return false
	end)

	expect(requestId).toBeNil()
	expect(reason).toBe("CommandAdmissionRefused")
	expect(fixture.sent).toEqual({})
	expect(clock.Count()).toBe(timers)
	expect((Commands.Send("Game.Ping"))).toBe(1)
end)

it("contains a throwing admission callback as an unsent refusal", function()
	local commands: Types.ClientCommandRuntime = runtime()

	local requestId: number?, reason: string? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		error("AdmissionExploded")
	end)

	expect(requestId).toBeNil()
	expect(reason).toBe("CommandAdmissionFailed")
	expect(fixture.sent).toEqual({})
end)

it("keeps ordinary command validation ahead of admission", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local consulted: boolean = false

	local requestId: number?, reason: string? = commands:_SendAdmitted("Game.Missing", nil, nil, function(): boolean
		consulted = true

		return true
	end)

	expect(requestId).toBeNil()
	expect(reason).toBe("UnknownCommand")
	expect(consulted).toBe(false)
end)

it("sends a command admitted from inside another admission after the lower id", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local inner: number? = nil

	local outer: number? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		inner = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
			return true
		end)

		return true
	end)

	expect(outer).toBe(1)
	expect(inner).toBe(2)
	expect(sentIds()).toEqual({ 1, 2 })
end)

it("never lets a send reentered from the transport overtake the packet being sent", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local reentered: boolean = false

	fixture.beforeSend = function(): ()
		if not reentered then
			reentered = true
			Commands.Send("Game.Ping")
		end
	end

	commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		return true
	end)

	expect(sentIds()).toEqual({ 1, 2 })
end)

it("observes outcomes synchronously before the public result Signal", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local order: { string } = {}
	local observed: { Types.CommandResult } = {}

	commands:_ObserveOutcomes(function(result: Types.CommandResult): ()
		table.insert(order, "private")
		table.insert(observed, result)
	end)

	Commands.OnCommandResult:Connect(function(): ()
		table.insert(order, "public")
	end)

	local requestId: number? = Commands.Send("Game.Ping")
	assert(requestId ~= nil, "Expected an admitted request")
	TestUtils.result(fixture, requestId, "Accepted")
	expect(#observed).toBe(1)
	expect(observed[1].requestId).toBe(requestId)
	expect(observed[1].commandId).toBe("Game.Ping")
	expect(observed[1].status).toBe("Accepted")
	task.wait()
	expect(order).toEqual({ "private", "public" })
end)

it("observes the Unknown emitted for unresolved commands when the connection closes", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local observed: { Types.CommandResult } = {}

	commands:_ObserveOutcomes(function(result: Types.CommandResult): ()
		table.insert(observed, result)
	end)

	local requestId: number? = Commands.Send("Game.Ping")
	Client._ResetForTests()
	expect(#observed).toBe(1)
	expect(observed[1].requestId).toBe(requestId)
	expect(observed[1].status).toBe("Unknown")
	expect(observed[1].reason).toBe("CommandConnectionClosed")
end)

it("stops notifying a disconnected private outcome observer", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local calls: number = 0

	local disconnect: () -> () = commands:_ObserveOutcomes(function(): ()
		calls += 1
	end)

	local first: number? = Commands.Send("Game.Ping")
	assert(first ~= nil, "Expected an admitted request")
	TestUtils.result(fixture, first, "Accepted")
	disconnect()
	disconnect()
	local second: number? = Commands.Send("Game.Ping")
	assert(second ~= nil, "Expected an admitted request")
	TestUtils.result(fixture, second, "Accepted")
	expect(calls).toBe(1)
end)

it("keeps a refused outer id unused while a nested admission that allocated past it still sends", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local inner: number? = nil

	local outer: number?, reason: string? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		inner = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
			return true
		end)

		return false
	end)

	expect(outer).toBeNil()
	expect(reason).toBe("CommandAdmissionRefused")
	expect(inner).toBe(2)
	expect(sentIds()).toEqual({ 2 })
	expect((Commands.Send("Game.Ping"))).toBe(3)
end)

it("sends nothing when the client resets while an admission callback runs", function()
	local commands: Types.ClientCommandRuntime = runtime()

	local requestId: number?, reason: string? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		Client._ResetForTests()

		return true
	end)

	expect(requestId).toBeNil()
	expect(reason).toBe("ClientNotReady")
	expect(fixture.sent).toEqual({})
end)

it("reports a yielding transport send as uncertain and keeps later packets flowing in order", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local observed: { Types.CommandResult } = {}
	local yielded: boolean = false

	commands:_ObserveOutcomes(function(result: Types.CommandResult): ()
		table.insert(observed, result)
	end)

	fixture.beforeSend = function(): ()
		if not yielded then
			yielded = true
			task.wait()
		end
	end

	local first: number?, reason: string? = commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		return true
	end)

	-- The send returns on the caller's stack; the packet's fate is unknown, not lost.
	expect(first).toBe(1)
	expect(reason).toBeNil()
	expect(#observed).toBe(1)
	expect(observed[1].requestId).toBe(1)
	expect(observed[1].status).toBe("Unknown")
	expect(observed[1].reason).toBe("CommandTransportYielded")

	expect((Commands.Send("Game.Ping"))).toBe(2)
	expect(sentIds()).toEqual({ 2 })

	-- The cancelled transport never resumes to send the stale packet out of order.
	task.wait()
	task.wait()
	expect(sentIds()).toEqual({ 2 })
end)

it("keeps egress live when a yielding transport is reached from a nested admission", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local yielded: boolean = false

	fixture.beforeSend = function(): ()
		if not yielded then
			yielded = true
			coroutine.yield()
		end
	end

	commands:_SendAdmitted("Game.Ping", nil, nil, function(): boolean
		Commands.Send("Game.Ping")

		return true
	end)

	expect(sentIds()).toEqual({ 2 })
	expect((Commands.Send("Game.Ping"))).toBe(3)
	expect(sentIds()).toEqual({ 2, 3 })
end)

it("contains a yielding private outcome observer without suspending result delivery", function()
	local commands: Types.ClientCommandRuntime = runtime()
	local later: { number } = {}

	commands:_ObserveOutcomes(function(): ()
		task.wait()
	end)

	commands:_ObserveOutcomes(function(result: Types.CommandResult): ()
		table.insert(later, result.requestId)
	end)

	local first: number? = Commands.Send("Game.Ping")
	assert(first ~= nil, "Expected an admitted request")
	TestUtils.result(fixture, first, "Accepted")
	expect(later).toEqual({ first })
	expect((Commands.Send("Game.Ping"))).toBe(2)
	expect(sentIds()).toEqual({ 1, 2 })
end)
