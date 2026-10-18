--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local SignalTypes = require(KRF.shared.Signal.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	GoodSignal.Fire = originalFire
	TestUtils.destroy(fixture)
end)

it("publishes Added synchronously with only the newly active visible aggregate", function()
	TestUtils.observe(fixture)
	TestUtils.add(fixture, "Status.Burning")
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Status.Burning" } },
			state = { ["Status.Burning"] = { stackCount = 1, expiresAt = 1010 } },
		},
	})
end)

it("refreshes finite timing from current synchronized time and emits Refreshed rather than Added", function()
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.observe(fixture)
	TestUtils.step(fixture, 2)
	TestUtils.add(fixture, "Status.Burning", 12)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Refreshed", payload = "Status.Burning" } },
			state = { ["Status.Burning"] = { stackCount = 1, expiresAt = 1014 } },
		},
	})
end)

it("increments aggregate stackCount and publishes Added for each new stack without exposing instances", function()
	TestUtils.add(fixture, "Buff.Stack", 3)
	TestUtils.observe(fixture)
	TestUtils.add(fixture, "Buff.Stack", 8)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Buff.Stack" } },
			state = { ["Buff.Stack"] = { stackCount = 2, expiresAt = 1008 } },
		},
	})
end)

it("retains a real Refreshed occurrence at stack cap even when aggregate state stays identical", function()
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.add(fixture, "Buff.Stack", 10)
	TestUtils.add(fixture, "Buff.Stack", 8)
	TestUtils.observe(fixture)
	TestUtils.add(fixture, "Buff.Stack", 5)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Refreshed", payload = "Buff.Stack" } },
			state = { ["Buff.Stack"] = { stackCount = 3, expiresAt = 1010 } },
		},
	})
end)

it("does not commit an Ignore duplicate after a real visible Add", function()
	TestUtils.observe(fixture)
	TestUtils.add(fixture, "Status.Permanent")
	expect(#fixture.commits).toBe(1)
	TestUtils.add(fixture, "Status.Permanent")
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Status.Permanent" } },
			state = { ["Status.Permanent"] = { stackCount = 1 } },
		},
	})
end)

it("removes the whole visible entry and emits Removed exactly once for manual RemoveTag", function()
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.add(fixture, "Buff.Stack", 8)
	TestUtils.observe(fixture)
	local removed: boolean, reason: string? = fixture.tags:RemoveTag("Buff.Stack")
	expect(reason).toBeNil()
	expect(removed).toBe(true)
	expect(fixture.commits).toEqual({ { events = { { id = "Removed", payload = "Buff.Stack" } }, state = {} } })
	local removedAgain: boolean, repeatedReason: string? = fixture.tags:RemoveTag("Buff.Stack")
	expect(removedAgain).toBe(false)
	expect(repeatedReason).toBe("TagNotActive")
	expect(#fixture.commits).toBe(1)
end)

it("decrements stacks on RemoveSingleTag and removes the final entry with distinct Removed occurrences", function()
	TestUtils.add(fixture, "Buff.Stack", 8)
	TestUtils.add(fixture, "Buff.Stack", 3)
	TestUtils.observe(fixture)
	expect(fixture.tags:RemoveSingleTag("Buff.Stack")).toBe(true)
	expect(fixture.tags:RemoveSingleTag("Buff.Stack")).toBe(true)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Removed", payload = "Buff.Stack" } },
			state = { ["Buff.Stack"] = { stackCount = 1, expiresAt = 1003 } },
		},
		{ events = { { id = "Removed", payload = "Buff.Stack" } }, state = {} },
	})
end)

it("uses Expired for authoritative partial and final stack expiry without fabricating Removed", function()
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.add(fixture, "Buff.Stack", 5)
	TestUtils.observe(fixture)
	TestUtils.step(fixture, 2)
	TestUtils.step(fixture, 3)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Expired", payload = "Buff.Stack" } },
			state = { ["Buff.Stack"] = { stackCount = 1, expiresAt = 1005 } },
		},
		{ events = { { id = "Expired", payload = "Buff.Stack" } }, state = {} },
	})
end)

it(
	"filters private Added, Refreshed, Removed and Expired before onCommitted while visible work still publishes",
	function()
		TestUtils.observe(fixture)
		TestUtils.add(fixture, "Private.Refresh")
		TestUtils.add(fixture, "Private.Refresh", 2)
		expect(fixture.tags:RemoveTag("Private.Refresh")).toBe(true)
		TestUtils.add(fixture, "Private.Refresh", 1)
		TestUtils.step(fixture, 1)
		TestUtils.add(fixture, "Private.Stack")
		TestUtils.add(fixture, "Private.Stack")
		expect(fixture.tags:RemoveSingleTag("Private.Stack")).toBe(true)
		expect(fixture.commits).toEqual({})
		TestUtils.add(fixture, "Status.Permanent")
		expect(fixture.commits).toEqual({
			{
				events = { { id = "Added", payload = "Status.Permanent" } },
				state = { ["Status.Permanent"] = { stackCount = 1 } },
			},
		})
	end
)

it("subscribes to the private Commit seam without connecting to any public asynchronous Tag event", function()
	local publicEvent: SignalTypes.Event<ActorTypes.Actor, string> = {
		Connect = function(): SignalTypes.Connection
			error("ReplicationMustNotSubscribeToPublicTagSignals")
		end,
		Once = function(): SignalTypes.Connection
			error("ReplicationMustNotSubscribeToPublicTagSignals")
		end,
		Wait = function(): (ActorTypes.Actor, string)
			error("ReplicationMustNotWaitForPublicTagSignals")
		end,
	}
	fixture.tags.OnTagAdded = publicEvent
	fixture.tags.OnTagRefreshed = publicEvent
	fixture.tags.OnTagRemoved = publicEvent
	fixture.tags.OnTagExpired = publicEvent
	fixture.tags.OnTagChanged = publicEvent
	local observations: number = 0
	local originalObserve = fixture.tags._observeMutations
	fixture.tags._observeMutations = function(
		self: TagTypes.InternalTagController,
		observer: TagTypes.TagMutationObserver
	): () -> ()
		observations += 1
		return originalObserve(self, observer)
	end
	TestUtils.observe(fixture)
	expect(observations).toBe(1)
	TestUtils.add(fixture, "Status.Permanent")
	expect(#fixture.commits).toBe(1)
end)

it("captures committed Add truth before public Fire can reenter and remove the same Tag", function()
	TestUtils.observe(fixture)
	local reentered: boolean = false
	GoodSignal.Fire = function(self: any, ...: any)
		local actor: any, tagId: any = ...
		if actor == fixture.actor and tagId == "Status.Permanent" and not reentered then
			reentered = true
			expect(fixture.commits).toEqual({
				{
					events = { { id = "Added", payload = "Status.Permanent" } },
					state = { ["Status.Permanent"] = { stackCount = 1 } },
				},
			})
			expect(fixture.tags:RemoveTag("Status.Permanent")).toBe(true)
		end
		originalFire(self, ...)
	end
	TestUtils.add(fixture, "Status.Permanent")
	expect(reentered).toBe(true)
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Added", payload = "Status.Permanent" } },
			state = { ["Status.Permanent"] = { stackCount = 1 } },
		},
		{ events = { { id = "Removed", payload = "Status.Permanent" } }, state = {} },
	})
end)
