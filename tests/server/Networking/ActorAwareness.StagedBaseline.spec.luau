--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, invalidation: string in { "retire", "fault", "replacement", "stream destroy", "runtime destroy" } do
	it("retains a staged baseline through reentrant " .. invalidation .. " until pump unwind", function()
		local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
		local player: Player = TestUtils.player(fixture)
		local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
		TestUtils.ready(fixture, player)
		runtime:Step(32768, 1)
		local internal: any = runtime
		local stream: any = internal.connections[player].actors[actor]
		local charge: any = stream.baseline.charge
		local originalBytes: number = internal.backlog.bytes
		local observedRecords, observedBytes = -1, -1
		local observedActive = false
		local observedKind = ""
		local send = fixture.dependencies.SendReliable

		fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
			local records = assert(fixture.codec.Decode(payload))
			observedKind = records[1].kind

			if invalidation == "retire" then
				runtime:OnActorUnregistering(actor)
			elseif invalidation == "fault" then
				stream:Fault("InjectedBaselineFault")
			elseif invalidation == "replacement" then
				TestUtils.associate(fixture, actor, player)
			elseif invalidation == "stream destroy" then
				stream:Destroy()
			else
				runtime:Destroy()
			end

			observedRecords = internal.backlog.records
			observedBytes = internal.backlog.bytes
			observedActive = charge.active

			return send(recipient, payload)
		end

		runtime:Step(32768, 1)
		fixture.dependencies.SendReliable = send
		expect(observedKind).toBe("BaselineChunk")
		expect(observedActive).toBe(true)
		expect(observedRecords).toBe(if invalidation == "replacement" then 2 else 1)
		expect(observedBytes >= originalBytes).toBe(true)
		expect(charge.active).toBe(false)
		expect(internal.backlog.records).toBe(if invalidation == "replacement" then 1 else 0)

		-- Repeated cleanup of the old lease must not debit replacement ownership.
		charge.release()
		stream:ReleaseStaged()
		expect(internal.backlog.records).toBe(if invalidation == "replacement" then 1 else 0)
		TestUtils.close(fixture, player)
		expect(internal.backlog.records).toBe(0)
		expect(internal.backlog.bytes).toBe(0)
	end)
end

it("releases an invalidated staged baseline once without debiting a re-Ready connection", function()
	local actor: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local player: Player = TestUtils.player(fixture)
	local runtime: Types.ActorAwarenessRuntime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
	local internal: any = runtime
	local stream: any = internal.connections[player].actors[actor]
	local charge: any = stream.baseline.charge
	local originalBytes: number = internal.backlog.bytes
	local observedRecords, observedBytes = -1, -1
	local observedActive = false
	local send = fixture.dependencies.SendReliable

	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		stream:Fault("InjectedBaselineFault")
		TestUtils.close(fixture, player)
		TestUtils.close(fixture, player)
		TestUtils.ready(fixture, player)
		observedRecords = internal.backlog.records
		observedBytes = internal.backlog.bytes
		observedActive = charge.active

		return send(recipient, payload)
	end

	runtime:Step(32768, 1)
	fixture.dependencies.SendReliable = send
	expect(observedActive).toBe(true)
	expect(observedRecords).toBe(2)
	expect(observedBytes).toBe(originalBytes)
	expect(charge.active).toBe(false)
	expect(internal.backlog.records).toBe(1)
	charge.release()
	stream:ReleaseStaged()
	expect(internal.backlog.records).toBe(1)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)
