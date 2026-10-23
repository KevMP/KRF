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
local Client = require(KRF.client)
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local Runtime = require(KRF.client.Networking.ClientCommandRuntime)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local fixture: TestUtils.Fixture
local clock = Clock.new()
local results: { Types.CommandResult }
local uncertain: { Types.CommandResult }
local original: typeof(Runtime.new) = Runtime.new

beforeEach(function()
	fixture = TestUtils.new()
	clock = Clock.new(100)
	Native.Now = clock.Now
	Native.ScheduleTimeout = clock.Schedule
	results = {}
	uncertain = {}

	Commands.OnCommandResult:Connect(function(result: Types.CommandResult): ()
		table.insert(results, result)
	end)

	Commands.OnCommandUncertain:Connect(function(result: Types.CommandResult): ()
		table.insert(uncertain, result)
	end)
end)

afterEach(function()
	fixture.cleanup()
	Runtime.new = original
	expect(clock.Count()).toBe(0)
end)

local function deliver(id: number, status: "Accepted" | "Rejected" | "Unknown", reason: string?, commandId: string?): ()
	TestUtils.result(fixture, id, status, reason, commandId)
end

it("correlates definitive results once with immutable public metadata and no private handles", function()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local first: number? = Commands.Send("Game.Ping")
	local second: number? = Commands.Send("Game.Interact", view, { choice = 1 })
	assert(first ~= nil and second ~= nil, "Expected admitted requests")
	deliver(first, "Accepted")
	deliver(second, "Rejected", "OutOfRange", "Game.Interact")
	task.wait()
	expect(results[1]).toEqual({ requestId = first, commandId = "Game.Ping", status = "Accepted" })

	expect(results[2]).toEqual({
		requestId = second,
		commandId = "Game.Interact",
		targetActorView = view,
		status = "Rejected",
		reason = "OutOfRange",
	})

	expect(table.isfrozen(results[2])).toBe(true)
	deliver(first, "Accepted")
	task.wait()
	expect(#results).toBe(2)
	expect(uncertain).toEqual({})
	expect(clock.Count()).toBe(0)
end)

it("reports timeout as uncertainty then accepts a late definitive outcome once within the grace window", function()
	TestUtils.ready(fixture)
	local id: number? = Commands.Send("Game.Ping")
	assert(id ~= nil, "Expected admitted request")
	clock.Advance(9.99)
	expect(uncertain).toEqual({})
	clock.Advance(0.01)

	expect(uncertain).toEqual({
		{ requestId = id, commandId = "Game.Ping", status = "Unknown", reason = "CommandTimeout" },
	})

	expect(results).toEqual({})
	deliver(id, "Accepted")
	task.wait()
	deliver(id, "Rejected", "Duplicate")
	task.wait()
	clock.Advance(100)
	expect(#uncertain).toBe(1)
	expect(#results).toBe(1)
	expect(results[1].status).toBe("Accepted")
end)

it("expires late-result grace, ignores mismatched/unknown ids and never synthesizes rejection", function()
	TestUtils.ready(fixture)
	local id: number? = Commands.Send("Game.Ping")
	assert(id ~= nil, "Expected request")
	deliver(id, "Rejected", "WrongCommand", "Game.Interact")
	deliver(id + 1, "Accepted")
	ClientUtils.emit(fixture.client, buffer.fromstring("invalid"))
	clock.Advance(20)
	deliver(id, "Accepted")
	task.wait()
	expect(results).toEqual({})
	expect(#uncertain).toBe(1)
	expect(clock.Count()).toBe(0)
end)

it(
	"routes server Unknown through the uncertainty Event without duplicate uncertainty on timeout or teardown",
	function()
		TestUtils.ready(fixture)
		local id: number? = Commands.Send("Game.Ping")
		assert(id ~= nil, "Expected request")
		deliver(id, "Unknown", "CommandHandlerFault")
		deliver(id, "Unknown", "CommandHandlerFault")
		task.wait()
		clock.Advance(10)
		Client._ResetForTests()
		expect(#uncertain).toBe(1)
		expect(uncertain[1].reason).toBe("CommandHandlerFault")
		expect(results).toEqual({})
	end
)

it("tears down every pending timer and cannot correlate old results into a new client session", function()
	TestUtils.ready(fixture)
	Commands.Send("Game.Ping")
	Commands.Send("Game.Ping")
	Client._ResetForTests()
	Client._ResetForTests()
	expect(#uncertain).toBe(2)

	for _, result: Types.CommandResult in uncertain do
		expect(result.reason).toBe("CommandConnectionClosed")
	end

	clock.Advance(100)
	deliver(1, "Accepted")
	expect(results).toEqual({})
end)

for _, bound: string in { "Count", "Bytes", "Id" } do
	it("enforces the pending " .. bound .. " bound before transmission and never reuses an admitted id", function()
		Runtime.new = function(
			protocol: SharedTypes.ClientProtocol,
			stream: Types.ActorStreamRuntime,
			options: Types.ClientCommandOptions
		): Types.ClientCommandRuntime
			if bound == "Count" then
				options.maxPending = 1
			end

			if bound == "Bytes" then
				options.maxPendingBytes = 41
			end

			if bound == "Id" then
				options.maxRequestId = 1
			end

			return original(protocol, stream, options)
		end

		TestUtils.ready(fixture)
		local first: number?, reason: string? = Commands.Send("Game.Ping")
		expect(first).toBe(1)
		expect(reason).toBeNil()
		local rejected: number? = nil
		rejected, reason = Commands.Send("Game.Ping")
		expect(rejected).toBeNil()
		expect(reason).toBe(if bound == "Id" then "RequestIdExhausted" else "CommandPendingFull")
		expect(#fixture.sent).toBe(1)
		deliver(1, "Accepted")
		task.wait()
		local nextId: number? = Commands.Send("Game.Ping")
		expect(nextId).toBe(if bound == "Id" then nil else 2)
	end)
end

it(
	"starts actual result callbacks before applying command-caused DomainView callbacks even when a listener yields",
	function()
		TestUtils.ready(fixture)
		local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
		local domain: PublicTypes.DomainView? = view:GetDomain("Game.Actions")
		assert(domain ~= nil, "Expected real DomainView")
		local observed: { string } = {}

		Commands.OnCommandResult:Connect(function(): ()
			table.insert(observed, "Result")
			task.wait()
		end)

		domain.OnChanged:Connect(function(): ()
			table.insert(observed, "Changed")
		end)

		local id: number? = Commands.Send("Game.Ping")
		assert(id ~= nil, "Expected request")
		deliver(id, "Accepted")

		TestUtils.records(fixture, {
			{
				kind = "Commit",
				handle = 7,
				revision = 2,
				patches = {
					{
						domainId = "Game.Actions",
						patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
					},
				},
				events = {},
			},
		})

		expect(domain:GetState().active).toBe(false)
		task.wait()
		expect(domain:GetState().active).toBe(true)
		expect(observed).toEqual({ "Result", "Changed" })
	end
)
