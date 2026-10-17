--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local Runtime: ServerNetworkingTypes.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)

local actor: ActorTypes.Actor
local domain: TestUtils.DomainFixture
local runtime: ServerNetworkingTypes.PublicationRuntime
local commits: { ServerNetworkingTypes.PublicationCommit } = {}
local faults: { ServerNetworkingTypes.PublicationFault } = {}

beforeEach(function()
	actor = ActorEntity.new()
	domain = TestUtils.createDomain("Game.State", Schema.Struct({ active = Schema.Boolean }), { active = false })
	domain.definition.events = { { id = "Changed", payload = Schema.Struct({ count = Schema.U8 }) } }
	commits = {}
	faults = {}
	runtime = TestUtils.createRuntime({ domain.definition }, {
		ReportFault = function(fault: ServerNetworkingTypes.PublicationFault): ()
			table.insert(faults, fault)
		end,
	})
end)

afterEach(function()
	runtime:Destroy()
end)

local function attach(): ()
	runtime:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		table.insert(commits, commit)
	end)
	local success: boolean, reason: string? = runtime:AttachActor(actor)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end

local function baseline(): ServerNetworkingTypes.PublicationBaseline
	local captured: ServerNetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
	assert(captured ~= nil, "Expected attached Actor baseline")
	return captured
end

it("captures initial truth exactly once without a commit or historical event", function()
	attach()
	expect(domain.snapshotCalls).toBe(1)
	expect(commits).toEqual({})
	expect(baseline()).toEqual({ sequence = 0, domains = { ["Game.State"] = { value = { active = false } } } })
	expect(runtime:GetActorSequence(actor)).toBe(0)
end)

it("keeps a top-level Optional nil domain present in every baseline", function()
	local optional: TestUtils.DomainFixture = TestUtils.createDomain("Game.Optional", Schema.Optional(Schema.U8), nil)
	runtime:Destroy()
	runtime = TestUtils.createRuntime({ optional.definition })
	local attached: boolean, reason: string? = runtime:AttachActor(actor)
	expect(attached).toBe(true)
	expect(reason).toBeNil()
	local initial: ServerNetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
	assert(initial ~= nil, "Expected attached Actor baseline")
	expect(initial).toEqual({ sequence = 0, domains = { ["Game.Optional"] = {} } })
	expect(initial.domains["Game.Optional"]).never.toBeNil()
	optional.value = 7
	optional.callbacks[actor]()
	optional.value = nil
	optional.callbacks[actor]()
	local current: ServerNetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
	expect(current).toEqual({ sequence = 2, domains = { ["Game.Optional"] = {} } })
end)

it("captures an ordinary notification before returning and preserves two immediate lifecycle boundaries", function()
	attach()
	domain.value.active = true
	domain.callbacks[actor]({ { id = "Changed", payload = { count = 1 } } })
	expect(domain.snapshotCalls).toBe(2)
	expect(commits[1].sequence).toBe(1)
	expect(commits[1].patches).toEqual({
		{
			domainId = "Game.State",
			patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
		},
	})
	domain.value.active = false
	domain.callbacks[actor]({ { id = "Changed", payload = { count = 2 } } })
	expect(#commits).toBe(2)
	expect(commits[1].patches[1].patch).toEqual({
		kind = "Struct",
		fields = { active = { kind = "Replace", value = true } },
	})
	expect(commits[2].patches[1].patch).toEqual({
		kind = "Struct",
		fields = { active = { kind = "Replace", value = false } },
	})
	expect(commits[2].sequence).toBe(2)
end)

it("does not advance sequence for unchanged state or an empty event list", function()
	attach()
	domain.callbacks[actor]()
	domain.callbacks[actor]({})
	expect(commits).toEqual({})
	expect(runtime:GetActorSequence(actor)).toBe(0)
	domain.value.active = true
	domain.callbacks[actor]()
	expect(#commits).toBe(1)
	expect(commits[1].sequence).toBe(1)
end)

it("publishes event-only commits in supplied order and captures consumer-owned payloads immediately", function()
	attach()
	local payload: any = { count = 1 }
	domain.callbacks[actor]({ { id = "Changed", payload = payload }, { id = "Changed", payload = { count = 2 } } })
	payload.count = 9
	expect(#commits).toBe(1)
	expect(commits[1].patches).toEqual({})
	expect(commits[1].events).toEqual({
		{ domainId = "Game.State", eventId = "Changed", payload = { count = 1 } },
		{ domainId = "Game.State", eventId = "Changed", payload = { count = 2 } },
	})
	expect(commits[1].sequence).toBe(1)
end)

it("retains stable baseline truth and its matching sequence while later source state changes", function()
	attach()
	local before: ServerNetworkingTypes.PublicationBaseline = baseline()
	domain.value.active = true
	domain.callbacks[actor]()
	expect(before).toEqual({ sequence = 0, domains = { ["Game.State"] = { value = { active = false } } } })
	expect(baseline()).toEqual({ sequence = 1, domains = { ["Game.State"] = { value = { active = true } } } })
	local thread: thread = coroutine.create(function(): ()
		runtime:CaptureBaseline(actor)
	end)
	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
end)

it("does not expose canonical tables as mutable baseline truth", function()
	attach()
	local exposed: ServerNetworkingTypes.PublicationBaseline = baseline()
	local _mutated: boolean = pcall(function(): ()
		exposed.domains["Game.State"].value.active = true
	end)
	expect(baseline().domains["Game.State"].value).toEqual({ active = false })
	expect(runtime:GetActorSequence(actor)).toBe(0)
end)

it("keeps sequences independent across Actors and reports only attached Actors", function()
	attach()
	local otherActor: ActorTypes.Actor = ActorEntity.new()
	local success: boolean, reason: string? = runtime:AttachActor(otherActor)
	expect(success).toBe(true)
	expect(reason).toBeNil()
	domain.value.active = true
	domain.callbacks[actor]()
	domain.callbacks[otherActor]()
	domain.value.active = false
	domain.callbacks[actor]()
	expect(runtime:GetActorSequence(actor)).toBe(2)
	expect(runtime:GetActorSequence(otherActor)).toBe(1)
	expect(#runtime:GetAttachedActors()).toBe(2)
	runtime:DetachActor(actor)
	expect(runtime:GetAttachedActors()).toEqual({ otherActor })
	expect(runtime:CaptureBaseline(actor)).toBeNil()
end)

for _, invalidEvents: { ReplicationTypes.ReplicationDomainEvent } in
	{
		{ { id = "Unknown", payload = { count = 1 } } },
		{ { id = "Changed", payload = { count = 256 } } },
		{ { id = "Changed", payload = { count = 1 } }, { id = "Unknown", payload = {} } },
	}
do
	it("rejects " .. invalidEvents[#invalidEvents].id .. " or malformed events atomically with state", function()
		attach()
		domain.value.active = true
		local success: boolean = pcall(function(): ()
			domain.callbacks[actor](invalidEvents)
		end)
		expect(success).toBe(false)
		expect(commits).toEqual({})
		expect(runtime:GetActorSequence(actor)).toBe(0)
		expect(baseline().domains["Game.State"].value).toEqual({ active = false })
		expect(faults[#faults]).toEqual({
			actorId = actor:GetId(),
			domainId = "Game.State",
			reason = "InvalidPublicationEvent",
		})
		domain.callbacks[actor]()
		expect(commits[1].sequence).toBe(1)
		expect(baseline().domains["Game.State"].value).toEqual({ active = true })
	end)
end

for _, invalidReport: { name: string, events: any } in
	{
		{ name = "unknown event", events = { { id = "Unknown", payload = {} } } },
		{
			name = "sparse event array",
			events = {
				[1] = { id = "Changed", payload = { count = 1 } },
				[3] = { id = "Changed", payload = { count = 2 } },
			},
		},
	}
do
	it("publishes a valid group after rejecting an ordinary " .. invalidReport.name, function()
		attach()
		local accepted: boolean, failure: any = pcall(function(): ()
			domain.callbacks[actor](invalidReport.events)
		end)
		expect(accepted).toBe(false)
		expect(failure).toBe("InvalidPublicationEvent:Game.State")
		expect(commits).toEqual({})
		expect(runtime:GetActorSequence(actor)).toBe(0)
		runtime:WithActorCommit(actor, function(): ()
			domain.value.active = true
			domain.callbacks[actor]()
		end)
		expect(#commits).toBe(1)
		expect(commits[1].sequence).toBe(1)
		expect(commits[1].patches).toEqual({
			{
				domainId = "Game.State",
				patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
			},
		})
		expect(baseline().domains["Game.State"].value).toEqual({ active = true })
	end)
end

it("does not replay a valid event prefix from a rejected report on the next notification", function()
	attach()
	local accepted: boolean = pcall(function(): ()
		domain.callbacks[actor]({
			{ id = "Changed", payload = { count = 1 } },
			{ id = "Unknown", payload = {} },
		})
	end)
	expect(accepted).toBe(false)
	domain.callbacks[actor]({ { id = "Changed", payload = { count = 2 } } })
	expect(#commits).toBe(1)
	expect(commits[1].events).toEqual({
		{ domainId = "Game.State", eventId = "Changed", payload = { count = 2 } },
	})
end)

it(
	"rejects an invalid snapshot without partial canonical mutation and reconciles on the next valid notification",
	function()
		attach()
		domain.value = { active = "invalid" }
		local success: boolean = pcall(function(): ()
			domain.callbacks[actor]()
		end)
		expect(success).toBe(false)
		expect(commits).toEqual({})
		expect(baseline().domains["Game.State"].value).toEqual({ active = false })
		expect(runtime:GetActorSequence(actor)).toBe(0)
		expect(faults[#faults]).toEqual({
			actorId = actor:GetId(),
			domainId = "Game.State",
			reason = "InvalidPublicationSnapshot",
		})
		domain.value = { active = true }
		domain.callbacks[actor]()
		expect(commits[1].sequence).toBe(1)
	end
)

it("isolates a throwing snapshot from other Actors and domains", function()
	local other: TestUtils.DomainFixture = TestUtils.createDomain("Game.Other", Schema.U8, 1)
	local otherActor: ActorTypes.Actor = ActorEntity.new()
	local shouldThrow: boolean = false
	local originalSnapshot: typeof(domain.definition.snapshot) = domain.definition.snapshot
	domain.definition.snapshot = function(snapshotActor: ActorTypes.Actor): any
		if snapshotActor == actor and shouldThrow then
			error("ProjectionFailure")
		end
		return originalSnapshot(snapshotActor)
	end
	runtime:Destroy()
	runtime = TestUtils.createRuntime({ domain.definition, other.definition }, {
		ReportFault = function(fault: ServerNetworkingTypes.PublicationFault): ()
			table.insert(faults, fault)
		end,
	})
	attach()
	expect(runtime:AttachActor(otherActor)).toBe(true)
	shouldThrow = true
	local success: boolean = pcall(function(): ()
		domain.callbacks[actor]()
	end)
	expect(success).toBe(false)
	expect(faults[#faults]).toEqual({
		actorId = actor:GetId(),
		domainId = "Game.State",
		reason = "PublicationSnapshotError",
	})
	expect(runtime:GetActorSequence(actor)).toBe(0)
	expect(baseline().domains["Game.State"].value).toEqual({ active = false })
	other.value = 2
	other.callbacks[actor]()
	expect(commits[1].patches).toEqual({ { domainId = "Game.Other", patch = { kind = "Replace", value = 2 } } })
	domain.value = { active = true }
	domain.callbacks[otherActor]()
	expect(runtime:GetActorSequence(otherActor)).toBe(1)
end)

it("unsubscribes commit observers idempotently without affecting other observers", function()
	local firstCalls: number = 0
	local unsubscribe: () -> () = runtime:ObserveCommits(function(): ()
		firstCalls += 1
	end)
	attach()
	unsubscribe()
	unsubscribe()
	domain.value.active = true
	domain.callbacks[actor]()
	expect(firstCalls).toBe(0)
	expect(#commits).toBe(1)
end)

it("admits the exact event ceiling and rejects one-byte overflow using compiled maximum size", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare({ domain.definition })
	local admitted: boolean, admittedReason: string? = Runtime.ValidateEventBounds(catalog, 1)
	expect(admitted).toBe(true)
	expect(admittedReason).toBeNil()
	local rejected: boolean, rejectedReason: string? = Runtime.ValidateEventBounds(catalog, 0)
	expect(rejected).toBe(false)
	expect(rejectedReason).toBe("PublicationEventTooLarge:Game.State:Changed")
end)

it("accepts an empty event catalog without inventing an event payload", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare({})
	local success: boolean, reason: string? = Runtime.ValidateEventBounds(catalog, 0)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end)

it("rejects a non-array event report without publishing changed state", function()
	attach()
	domain.value.active = true
	local accepted: boolean = pcall(function(): ()
		(domain.callbacks[actor] :: any)("invalid")
	end)
	expect(accepted).toBe(false)
	expect(commits).toEqual({})
	expect(runtime:GetActorSequence(actor)).toBe(0)
	expect(baseline().domains["Game.State"].value).toEqual({ active = false })
	expect(faults[#faults]).toEqual({
		actorId = actor:GetId(),
		domainId = "Game.State",
		reason = "InvalidPublicationEvent",
	})
end)

for _, invalidReport: { name: string, events: any } in
	{
		{
			name = "sparse",
			events = {
				[1] = { id = "Changed", payload = { count = 1 } },
				[3] = { id = "Changed", payload = { count = 3 } },
			},
		},
		{
			name = "dictionary-shaped",
			events = { First = { id = "Changed", payload = { count = 1 } } },
		},
	}
do
	it("rejects a " .. invalidReport.name .. " event collection atomically", function()
		attach()
		domain.value.active = true
		local accepted: boolean, failure: any = pcall(function(): ()
			(domain.callbacks[actor] :: any)(invalidReport.events)
		end)
		expect(accepted).toBe(false)
		expect(failure).toBe("InvalidPublicationEvent:Game.State")
		expect(commits).toEqual({})
		expect(runtime:GetActorSequence(actor)).toBe(0)
		expect(baseline().domains["Game.State"].value).toEqual({ active = false })
		expect(faults[#faults]).toEqual({
			actorId = actor:GetId(),
			domainId = "Game.State",
			reason = "InvalidPublicationEvent",
		})
		domain.callbacks[actor]()
		expect(#commits).toBe(1)
		expect(commits[1].events).toEqual({})
	end)
end
