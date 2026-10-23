--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local Client = require(KRF.client)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Commands = require(script.Parent.Parent.shared.Utils.Networking.CommandTestUtils)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	fixture.cleanup()
end)

local function expectRejected(runtime: Commands.Facade, id: string, view: PublicTypes.ActorView?, payload: any): ()
	local sentBefore: number = #fixture.sent
	local requestId: number?, reason: string? = runtime.Send(id, view, payload)
	expect(requestId).toBeNil()
	expect(type(reason)).toBe("string")
	assert(reason ~= nil, "Local admission failure must have a reason")
	expect(#reason > 0).toBe(true)
	expect(#fixture.sent).toBe(sentBefore)
end

it("admits the exact available registry-owned ActorView even when no Model is bound", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	expect(Registry.GetActorViewById(view:GetId())).toBe(view)
	expect(view:IsAvailable()).toBe(true)
	expect(view:GetModel()).toBeNil()
	local requestId: number?, reason: string? = runtime.Send("Game.Interact", view, { choice = 3 })
	expect(reason).toBeNil()
	assert(requestId ~= nil, "Successful local admission returns a raw request id")
	expect(requestId > 0 and requestId % 1 == 0).toBe(true)
	expect(#fixture.sent).toBe(1)
	expect(string.find(buffer.tostring(fixture.sent[1]), view:GetId(), 1, true)).toBeNil()
	-- Positive fixed-width private targeting is covered by the native wire fixture.
end)

it("rejects a forged view copying every public member of the exact live view", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local forged: any = table.clone(view :: any)
	expect(forged:GetId()).toBe(view:GetId())
	expect(forged:IsAvailable()).toBe(true)
	expectRejected(runtime, "Game.Interact", forged, { choice = 3 })
end)

it("rejects a genuine view owned by a previous Client.Init after the same Actor id reappears", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local previous: PublicTypes.ActorView = TestUtils.baseline(fixture)
	fixture.cleanup()
	fixture = TestUtils.new()
	TestUtils.ready(fixture)
	local current: PublicTypes.ActorView = TestUtils.baseline(fixture, 19, previous:GetId())
	expect(current).never.toBe(previous)
	expect(Registry.GetActorViewById(previous:GetId())).toBe(current)
	expectRejected(runtime, "Game.Interact", previous, { choice = 3 })
	local requestId: number?, reason: string? = runtime.Send("Game.Interact", current, { choice = 3 })
	expect(reason).toBeNil()
	expect(type(requestId)).toBe("number")
	expect(#fixture.sent).toBe(1)
end)

for _, terminal: string in { "ActorRemove", "ActorHalt", "RecoveryExhaustion" } do
	it("rejects the formerly live view after " .. terminal .. " without transmitting", function()
		local runtime: Commands.Facade = Commands.runtime()
		TestUtils.ready(fixture)
		local view: PublicTypes.ActorView = TestUtils.baseline(fixture)

		if terminal == "RecoveryExhaustion" then
			TestUtils.records(fixture, { { kind = "Commit", handle = 7, revision = 3, patches = {}, events = {} } })
			expect(view:IsAvailable()).toBe(true)

			-- Complete the existing N5 adapter's five scheduled recovery opportunities.
			for _ = 1, 5 do
				local timeout: (() -> ())? = fixture.client.timeoutCallback
				assert(timeout ~= nil, "Expected owned N5 recovery timer")
				timeout()
			end
		elseif terminal == "ActorRemove" then
			TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
		else
			TestUtils.records(fixture, { { kind = "ActorHalt", handle = 7 } })
		end

		expect(view:IsAvailable()).toBe(false)
		expectRejected(runtime, "Game.Interact", view, { choice = 3 })
	end)
end

it("admits the exact still-available view while N5 retains last valid truth during recoverable desync", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	TestUtils.records(fixture, { { kind = "Commit", handle = 7, revision = 3, patches = {}, events = {} } })
	expect(Registry.GetActorViewById(view:GetId())).toBe(view)
	expect(view:IsAvailable()).toBe(true)
	local id: number?, reason: string? = runtime.Send("Game.Interact", view, { choice = 3 })
	expect(reason).toBeNil()
	expect(type(id)).toBe("number")
end)

it("rejects a retired view after removal and relearning the same id under a new private handle", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local retired: PublicTypes.ActorView = TestUtils.baseline(fixture)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	local current: PublicTypes.ActorView = TestUtils.baseline(fixture, 19, retired:GetId())
	expect(Registry.GetActorViewById(retired:GetId())).toBe(current)
	expect(current).never.toBe(retired)
	expectRejected(runtime, "Game.Interact", retired, { choice = 3 })
end)

it("requires the declared target presence and validates the request locally before transmission", function()
	local runtime: Commands.Facade = Commands.runtime()
	TestUtils.ready(fixture)
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	expectRejected(runtime, "Game.Unknown", nil, nil)
	expectRejected(runtime, "Game.Ping", view, nil)
	expectRejected(runtime, "Game.Interact", nil, { choice = 3 })
	expectRejected(runtime, "Game.Interact", view, { choice = 256 })
	expectRejected(runtime, "Game.Interact", view, { choice = "3" })
	expectRejected(runtime, "Game.Interact", view, nil)
	expectRejected(runtime, "Game.Ping", nil, { unexpected = true })
	expect(#fixture.sent).toBe(0)
	Client._ResetForTests()
end)
