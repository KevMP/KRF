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
local PublicTypes = require(KRF.client.Actor.types)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Runtime = require(KRF.client.Networking.ClientCommandRuntime)
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local State = require(KRF.client.Networking.utils.CommandRuntimeState)
local Actors = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local RegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Client = require(KRF.client)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local fixture: TestUtils.Fixture
local clock = Clock.new()
local original: typeof(Runtime.new) = Runtime.new
local uncertain: { Types.CommandResult }
local owners: { PublicTypes.ActorViewOwner }

beforeEach(function()
	fixture = TestUtils.new()
	clock = Clock.new(100)
	Native.Now = clock.Now
	Native.ScheduleTimeout = clock.Schedule
	uncertain = {}
	owners = {}

	Commands.OnCommandUncertain:Connect(function(result: Types.CommandResult): ()
		table.insert(uncertain, result)
	end)
end)

afterEach(function()
	fixture.cleanup()

	for _, owner: PublicTypes.ActorViewOwner in owners do
		owner:Destroy()
	end

	Runtime.new = original
	expect(clock.Count()).toBe(0)
end)

for _, bound: string in { "Records", "Bytes" } do
	it(
		"bounds deferred Reliable " .. bound .. " and releases pending requests and Actor consumers on overflow",
		function()
			TestUtils.ready(fixture)
			local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
			Commands.Send("Game.Ping")
			Commands.Send("Game.Ping")
			TestUtils.result(fixture, 1, "Accepted", nil, nil)
			local payload: buffer = buffer.create(if bound == "Bytes" then Constants.MAX_FENCED_BYTES + 1 else 1)
			buffer.writeu8(payload, 0, ActorConstants.PACKET_KIND)
			local count: number = if bound == "Bytes" then 1 else Constants.MAX_FENCED_RECORDS + 1

			for _ = 1, count do
				ClientUtils.emit(fixture.client, payload)
			end

			expect(view:IsAvailable()).toBe(false)
			expect(Registry.GetAllActorViews()).toEqual({})

			expect(uncertain).toEqual({
				{ requestId = 2, commandId = "Game.Ping", status = "Unknown", reason = "CommandConnectionClosed" },
			})

			local id: number?, reason: string? = Commands.Send("Game.Ping")
			expect(id).toBeNil()
			expect(reason).toBe("ClientNotReady")
			task.wait()
			expect(clock.Count()).toBe(0)
		end
	)
end

it("reports a thrown transport send as uncertainty after admission and does not repeat it at timeout", function()
	local originalSend: (buffer) -> () = fixture.client.transport.SendReliable

	fixture.client.transport.SendReliable = function(payload: buffer): ()
		if buffer.readu8(payload, 0) == Constants.REQUEST_KIND then
			error("TransportFault")
		end

		originalSend(payload)
	end

	TestUtils.ready(fixture)
	local id: number?, reason: string? = Commands.Send("Game.Ping")
	expect(id).toBe(1)
	expect(reason).toBeNil()
	expect(uncertain[1].reason).toBe("CommandTransportFault")
	clock.Advance(100)
	expect(#uncertain).toBe(1)
end)

it("discards malformed result envelopes without pausing subsequent valid Actor reception", function()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local bad: buffer = buffer.create(1)
	buffer.writeu8(bad, 0, Constants.RESULT_KIND)
	ClientUtils.emit(fixture.client, bad)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	expect(view:IsAvailable()).toBe(false)
	expect(uncertain).toEqual({})
end)

it("cancels deferred Actor work when a result callback tears down the client", function()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local private: Types.ClientCommandRuntime? = State.Get()
	assert(private ~= nil, "Expected private installed runtime")

	Commands.OnCommandResult:Connect(function(): ()
		Client._ResetForTests()
	end)

	Commands.Send("Game.Ping")
	TestUtils.result(fixture, 1, "Accepted", nil, nil)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	task.wait()
	expect(Registry.GetAllActorViews()).toEqual({})
	expect(view:IsAvailable()).toBe(false)
	expect(private:Handle(buffer.create(1))).toBe(false)
	expect((private:Send("Game.Ping", nil, nil))).toBeNil()
	expect(uncertain).toEqual({})
end)

it("rejects an owned available view when its private stream mapping is missing", function()
	TestUtils.ready(fixture)
	local owner: PublicTypes.ActorViewOwner? = Actors.new("Orphan", nil, {})
	assert(owner ~= nil, "Expected real public ActorView owner")
	table.insert(owners, owner)
	expect((RegistryOwner.Install(owner.view))).toBe(true)
	local id: number?, reason: string? = Commands.Send("Game.Interact", owner.view, { choice = 1 })
	expect(id).toBeNil()
	expect(reason).toBe("ActorViewUnavailable")
	expect(fixture.sent).toEqual({})
end)

it("requires both private stream indexes to identify the exact same live record", function()
	Runtime.new = function(
		protocol: SharedTypes.ClientProtocol,
		stream: Types.ActorStreamRuntime,
		options: Types.ClientCommandOptions
	): Types.ClientCommandRuntime
		stream.GetByHandle = function(_self: Types.ActorStreamRuntime, _handle: number): Types.ActorStreamRecord?
			return nil
		end

		return original(protocol, stream, options)
	end

	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local id: number?, reason: string? = Commands.Send("Game.Interact", view, { choice = 1 })
	expect(id).toBeNil()
	expect(reason).toBe("ActorViewUnavailable")
end)
