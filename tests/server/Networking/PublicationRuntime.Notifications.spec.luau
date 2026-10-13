--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local ReplicationTypes = require(KRF.server.Replication.types)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local Runtime: PublicationTypes.RuntimeModule = require(KRF.server.Networking.PublicationRuntime)

local actor: ActorTypes.Actor
local domain: TestUtils.DomainFixture
local runtime: PublicationTypes.Runtime
local commits: { PublicationTypes.Commit } = {}
local faults: { PublicationTypes.Fault } = {}

beforeEach(function()
	actor = ActorEntity.new()
	domain = TestUtils.createDomain("Game.State", Schema.Struct({ active = Schema.Boolean }), { active = false })
	domain.definition.events = { { id = "Changed", payload = Schema.Struct({ count = Schema.U8 }) } }
	commits = {}
	faults = {}
	runtime = TestUtils.createRuntime({ domain.definition }, {
		ReportFault = function(fault: PublicationTypes.Fault): ()
			table.insert(faults, fault)
		end,
	})
end)

afterEach(function()
	runtime:Destroy()
end)

local function attach(): ()
	runtime:ObserveCommits(function(commit: PublicationTypes.Commit): ()
		table.insert(commits, commit)
	end)
	local success: boolean, reason: string? = runtime:AttachActor(actor)
	expect(success).toBe(true)
	expect(reason).toBeNil()
end

local function baseline(): PublicationTypes.Baseline
	local captured: PublicationTypes.Baseline? = runtime:CaptureBaseline(actor)
	assert(captured ~= nil, "Expected attached Actor baseline")
	return captured
end

it("captures initial truth exactly once without a commit or historical event", function()
	attach()
	expect(domain.snapshotCalls).toBe(1)
	expect(commits).toEqual({})
	expect(baseline()).toEqual({ sequence = 0, domains = { ["Game.State"] = { active = false } } })
	expect(runtime:GetActorSequence(actor)).toBe(0)
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
	local before: PublicationTypes.Baseline = baseline()
	domain.value.active = true
	domain.callbacks[actor]()
	expect(before).toEqual({ sequence = 0, domains = { ["Game.State"] = { active = false } } })
	expect(baseline()).toEqual({ sequence = 1, domains = { ["Game.State"] = { active = true } } })
	local thread: thread = coroutine.create(function(): ()
		runtime:CaptureBaseline(actor)
	end)
	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
end)

it("does not expose canonical tables as mutable baseline truth", function()
	attach()
	local exposed: PublicationTypes.Baseline = baseline()
	local _mutated: boolean = pcall(function(): ()
		exposed.domains["Game.State"].active = true
	end)
	expect(baseline().domains["Game.State"]).toEqual({ active = false })
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
		expect(baseline().domains["Game.State"]).toEqual({ active = false })
		expect(faults[#faults]).toEqual({
			actorId = actor:GetId(),
			domainId = "Game.State",
			reason = "InvalidPublicationEvent",
		})
		domain.callbacks[actor]()
		expect(commits[1].sequence).toBe(1)
		expect(baseline().domains["Game.State"]).toEqual({ active = true })
	end)
end

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
		expect(baseline().domains["Game.State"]).toEqual({ active = false })
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
		ReportFault = function(fault: PublicationTypes.Fault): ()
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
	expect(baseline().domains["Game.State"]).toEqual({ active = false })
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
