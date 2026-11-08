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
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local State = require(KRF.client.Networking.utils.CommandRuntimeState)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local fixture: TestUtils.Fixture
local clock = Clock.new()

local COMMANDS: { SharedTypes.ManifestCommand } = {
	{ id = "Game.Ping", code = 0, target = "None" },
	{ id = "Game.Stop", code = 1, target = "None" },
}

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
	TestUtils.ready(fixture, nil, COMMANDS)
	local installed: Types.ClientCommandRuntime? = State.Get()
	assert(installed ~= nil, "Expected the installed private command runtime")

	return installed
end

local function admitted(): boolean
	return true
end

local function fill(commands: Types.ClientCommandRuntime, commandId: string): (number, string?)
	local count: number = 0

	while true do
		local requestId: number?, reason: string? = commands:_SendAdmitted(commandId, nil, nil, admitted)

		if requestId == nil then
			return count, reason
		end

		count += 1
	end
end

it("keeps pending headroom that ordinary commands cannot consume", function()
	local commands: Types.ClientCommandRuntime = runtime()
	expect((commands:_ClassifyFollowUps({ "Game.Stop" }))).toBe(true)

	local ordinary: number, ordinaryReason: string? = fill(commands, "Game.Ping")
	expect(ordinary).toBe(112)
	expect(ordinaryReason).toBe("CommandPendingFull")

	-- Follow-ups use the headroom and the shared total, never more than the total.
	local followUps: number, followUpReason: string? = fill(commands, "Game.Stop")
	expect(followUps).toBe(16)
	expect(followUpReason).toBe("CommandPendingFull")
	expect(#fixture.sent).toBe(128)
end)

it("admits a Stop after ordinary sends fill their share, then frees the slot on its result", function()
	local commands: Types.ClientCommandRuntime = runtime()
	commands:_ClassifyFollowUps({ "Game.Stop" })
	fill(commands, "Game.Ping")

	local stop: number? = commands:_SendAdmitted("Game.Stop", nil, nil, admitted)
	assert(stop ~= nil, "Expected the protected Stop admission")
	TestUtils.result(fixture, stop, "Accepted", nil, "Game.Stop")
	expect((commands:_SendAdmitted("Game.Ping", nil, nil, admitted))).toBeNil()
	expect((commands:_SendAdmitted("Game.Stop", nil, nil, admitted))).never.toBeNil()
end)

it("gives ordinary commands the whole bound when no follow-ups are classified", function()
	local commands: Types.ClientCommandRuntime = runtime()
	expect((fill(commands, "Game.Ping"))).toBe(128)
	expect((commands:_SendAdmitted("Game.Stop", nil, nil, admitted))).toBeNil()
end)

it("restores the whole bound when the classification is cleared", function()
	local commands: Types.ClientCommandRuntime = runtime()
	commands:_ClassifyFollowUps({ "Game.Stop" })
	commands:_ClassifyFollowUps({})
	expect((fill(commands, "Game.Ping"))).toBe(128)
end)

it("rejects classifying a command the protocol does not publish", function()
	local commands: Types.ClientCommandRuntime = runtime()
	commands:_ClassifyFollowUps({ "Game.Stop" })

	local classified: boolean, reason: string? = commands:_ClassifyFollowUps({ "Game.Stop", "Game.Missing" })
	expect(classified).toBe(false)
	expect(reason).toBe("UnknownCommand")

	-- The previous classification is left intact.
	expect((fill(commands, "Game.Ping"))).toBe(112)
end)
