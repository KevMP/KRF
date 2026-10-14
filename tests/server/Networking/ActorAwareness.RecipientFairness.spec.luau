--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, backlogKind: string in { "join", "replacement" } do
	it(
		"services another recipient's live work before draining a large " .. backlogKind .. " baseline backlog",
		function()
			fixture.options.maxChunkBytes = 1
			local actors: { ActorTypes.Actor } = {}
			for _ = 1, 12 do
				table.insert(actors, TestUtils.actor(fixture, nil))
			end
			local runtime: Types.Runtime = TestUtils.start(fixture)
			local backlogRecipient: Player = TestUtils.player(fixture)
			local liveRecipient: Player = TestUtils.player(fixture)
			-- Test both a late joiner and an earlier connection that restarts many baselines.
			if backlogKind == "replacement" then
				TestUtils.ready(fixture, backlogRecipient)
			end
			TestUtils.ready(fixture, liveRecipient)
			TestUtils.drain(fixture)
			TestUtils.drain(fixture)
			expect(#TestUtils.kind(fixture, liveRecipient, "BaselineEnd")).toBe(#actors)
			local liveHandle: number? = runtime:GetHandle(liveRecipient, actors[1])
			assert(liveHandle ~= nil, "Expected already-live Actor")
			fixture.deliveries = {}
			if backlogKind == "join" then
				TestUtils.ready(fixture, backlogRecipient)
			else
				for _, actor: ActorTypes.Actor in actors do
					local handle: number? = runtime:GetHandle(backlogRecipient, actor)
					assert(handle ~= nil, "Expected established recipient stream")
					local accepted: boolean, reason: string? =
						runtime:RequestReplacementBaseline(backlogRecipient, handle, nil)
					expect(accepted).toBe(true)
					expect(reason).toBeNil()
				end
			end
			fixture.publicDomain.value = 11
			fixture.publicDomain.callbacks[actors[1]]()
			local serviced: boolean = false
			for _ = 1, 32 do
				local previousSends: number = #fixture.deliveries
				runtime:Step(96, 1)
				local emittedRecords: number = 0
				for index: number = previousSends + 1, #fixture.deliveries do
					local delivery: TestUtils.Delivery = fixture.deliveries[index]
					expect(buffer.len(delivery.payload) <= 96).toBe(true)
					local records: { WireTypes.Record }?, reason: string? = fixture.codec.Decode(delivery.payload)
					expect(reason).toBeNil()
					assert(records ~= nil, "Expected bounded Actor packet")
					emittedRecords += #records
				end
				expect(emittedRecords <= 1).toBe(true)
				local live: { any } = TestUtils.kind(fixture, liveRecipient, "Commit")
				if #live > 0 then
					expect(#live).toBe(1)
					expect(live[1].handle).toBe(liveHandle)
					expect(live[1].patches).toEqual({
						{ domainId = "Game.Public", patch = { kind = "Replace", value = 11 } },
					})
					expect(#TestUtils.kind(fixture, backlogRecipient, "BaselineEnd") < #actors).toBe(true)
					serviced = true
					break
				end
			end
			expect(serviced).toBe(true)
		end
	)
end
