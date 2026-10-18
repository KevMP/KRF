--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local TestUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local Types = require(ReplicatedStorage.Packages.KRF.client.Networking.types)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reports undecodable packet framing once without attributing it to an Actor", function()
	local runtime: Types.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local actor: Types.ActorStreamRecord? = runtime:GetByHandle(1)
	local accepted: boolean, reason: string? = runtime:Handle(buffer.create(0))
	expect(accepted).toBe(false)
	expect(reason).toBe("MalformedActorPacket")
	expect(fixture.faults).toEqual({ "MalformedActorPacket" })
	expect(runtime:GetByHandle(1)).toBe(actor)
	expect(fixture.halted).toEqual({})
	expect(fixture.removed).toEqual({})
	expect(fixture.commits).toEqual({})
end)

it("continues unrelated Actor records in a decoded packet after an Actor-local failure", function()
	TestUtils.start(fixture)
	TestUtils.establish(fixture, 1, "ActorA", 1, 1)
	TestUtils.establish(fixture, 2, "ActorB", 1, 1)
	local accepted: boolean, reason: string? = TestUtils.send(fixture, {
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 2 },
		{ kind = "Commit", handle = 2, revision = 2, patches = {}, events = {} },
	})
	expect(accepted).toBe(false)
	expect(reason).toBe("BaselineNotPending")
	expect(fixture.faults).toEqual({ "BaselineNotPending" })
	expect(#fixture.commits).toBe(1)
	expect(fixture.commits[1].actor.actorId).toBe("ActorB")
	expect(fixture.commits[1].revision).toBe(2)
	expect(fixture.removed).toEqual({})
end)
