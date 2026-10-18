--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local runtime: ServerNetworkingTypes.PublicationRuntime? = nil
afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
end)

type AttachmentFailureCase = { name: string, configure: (fixture: TestUtils.DomainFixture) -> (), reason: string }
local failures: { AttachmentFailureCase } = {
	{
		name = "invalid initial snapshot",
		configure = function(fixture: TestUtils.DomainFixture): ()
			fixture.value = 256
		end,
		reason = "InvalidPublicationSnapshot:Game.B",
	},
	{
		name = "throwing initial snapshot",
		configure = function(fixture: TestUtils.DomainFixture): ()
			fixture.definition.snapshot = function(): any
				error("SnapshotFailure")
			end
		end,
		reason = "PublicationSnapshotError:Game.B",
	},
	{
		name = "yielding initial snapshot",
		configure = function(fixture: TestUtils.DomainFixture): ()
			fixture.definition.snapshot = function(): any
				coroutine.yield()
				return 1
			end
		end,
		reason = "PublicationSnapshotYielded:Game.B",
	},
	{
		name = "throwing observe adapter",
		configure = function(fixture: TestUtils.DomainFixture): ()
			fixture.definition.observe = function(): (() -> ())?
				error("ObserveFailure")
			end
		end,
		reason = "PublicationObserveError:Game.B",
	},
}

for _, case: AttachmentFailureCase in failures do
	it("rejects " .. case.name .. " and cleans all earlier domain attachment work", function()
		local actor: ActorTypes.Actor = ActorEntity.new()
		local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 1)
		local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 1)
		case.configure(second)
		local publication: ServerNetworkingTypes.PublicationRuntime =
			TestUtils.createRuntime({ first.definition, second.definition })
		runtime = publication
		local commits: { ServerNetworkingTypes.PublicationCommit } = {}
		publication:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
			table.insert(commits, commit)
		end)
		local success: boolean?, reason: string? = nil, nil
		local thread: thread = coroutine.create(function(): ()
			success, reason = publication:AttachActor(actor)
		end)
		expect(coroutine.resume(thread)).toBe(true)
		expect(coroutine.status(thread)).toBe("dead")
		expect(success).toBe(false)
		expect(reason).toBe(case.reason)
		expect(first.disconnectCalls).toBe(1)
		expect(publication:GetAttachedActors()).toEqual({})
		expect(publication:CaptureBaseline(actor)).toBeNil()
		first.value = 2
		first.callbacks[actor]()
		expect(commits).toEqual({})
		publication:DetachActor(actor)
		expect(first.disconnectCalls).toBe(1)
	end)
end

it("rejects a yielding observe adapter synchronously, unwinds attachment, and can attach normally afterward", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 1)
	local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 1)
	local shouldYield: boolean = true
	local originalObserve = second.definition.observe
	assert(originalObserve ~= nil, "Expected fixture observation adapter")
	second.definition.observe = function(
		observedActor: ActorTypes.Actor,
		onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		if shouldYield then
			coroutine.yield()
		end
		return originalObserve(observedActor, onCommitted)
	end
	local publication: ServerNetworkingTypes.PublicationRuntime =
		TestUtils.createRuntime({ first.definition, second.definition })
	runtime = publication
	local commits: { ServerNetworkingTypes.PublicationCommit } = {}
	publication:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		table.insert(commits, commit)
	end)
	local attached: boolean? = nil
	local reason: string? = nil
	local thread: thread = coroutine.create(function(): ()
		attached, reason = publication:AttachActor(actor)
	end)
	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
	expect(attached).toBe(false)
	expect(reason).toBe("PublicationObserveYielded:Game.B")
	expect(first.disconnectCalls).toBe(1)
	expect(publication:GetAttachedActors()).toEqual({})
	shouldYield = false
	local retrySuccess: boolean, retryReason: string? = publication:AttachActor(actor)
	expect(retrySuccess).toBe(true)
	expect(retryReason).toBeNil()
	second.value = 2
	second.callbacks[actor]()
	expect(#commits).toBe(1)
	expect(commits[1].patches).toEqual({ { domainId = "Game.B", patch = { kind = "Replace", value = 2 } } })
end)

it("captures domains with no observe adapter or no returned disconnect", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 1)
	local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 2)
	first.definition.observe = nil
	second.definition.observe = function(
		_actor: ActorTypes.Actor,
		_notify: ReplicationTypes.ReplicationDomainOnCommitted
	): (() -> ())?
		return nil
	end
	local publication: ServerNetworkingTypes.PublicationRuntime =
		TestUtils.createRuntime({ first.definition, second.definition })
	runtime = publication
	local success: boolean, reason: string? = publication:AttachActor(actor)
	expect(success).toBe(true)
	expect(reason).toBeNil()
	expect(first.snapshotCalls).toBe(1)
	expect(second.snapshotCalls).toBe(1)
	expect(publication:CaptureBaseline(actor)).toEqual({
		sequence = 0,
		domains = { ["Game.A"] = { value = 1 }, ["Game.B"] = { value = 2 } },
	})
	publication:DetachActor(actor)
	publication:DetachActor(actor)
	expect(publication:GetAttachedActors()).toEqual({})
end)

it("disconnects every observer exactly once and ignores stale producer callbacks after detach", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 1)
	local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 2)
	local publication: ServerNetworkingTypes.PublicationRuntime =
		TestUtils.createRuntime({ first.definition, second.definition })
	runtime = publication
	local commits: { ServerNetworkingTypes.PublicationCommit } = {}
	publication:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		table.insert(commits, commit)
	end)
	expect(publication:AttachActor(actor)).toBe(true)
	publication:DetachActor(actor)
	publication:DetachActor(actor)
	expect(first.disconnectCalls).toBe(1)
	expect(second.disconnectCalls).toBe(1)
	first.value = 3
	first.callbacks[actor]()
	second.callbacks[actor]()
	expect(commits).toEqual({})
	expect(first.snapshotCalls).toBe(1)
	expect(publication:CaptureBaseline(actor)).toBeNil()
end)

it("continues teardown after a disconnect throws and reports Actor/domain context", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 1)
	local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 2)
	first.definition.observe = function(): () -> ()
		return function(): ()
			error("DisconnectFailure")
		end
	end
	local faults: { ServerNetworkingTypes.PublicationFault } = {}
	local publication: ServerNetworkingTypes.PublicationRuntime = TestUtils.createRuntime(
		{ first.definition, second.definition },
		{
			ReportFault = function(fault: ServerNetworkingTypes.PublicationFault): ()
				table.insert(faults, fault)
			end,
		}
	)
	runtime = publication
	expect(publication:AttachActor(actor)).toBe(true)
	local success: boolean = pcall(function(): ()
		publication:DetachActor(actor)
	end)
	expect(success).toBe(true)
	expect(second.disconnectCalls).toBe(1)
	expect(publication:GetAttachedActors()).toEqual({})
	expect(faults).toEqual({ { actorId = actor:GetId(), domainId = "Game.A", reason = "PublicationDisconnectError" } })
end)

it("destroys all live attachments idempotently without retaining Actor history", function()
	local firstActor: ActorTypes.Actor = ActorEntity.new()
	local secondActor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 1)
	local publication: ServerNetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
	runtime = publication
	expect(publication:AttachActor(firstActor)).toBe(true)
	expect(publication:AttachActor(secondActor)).toBe(true)
	publication:Destroy()
	publication:Destroy()
	expect(domain.disconnectCalls).toBe(2)
	expect(publication:GetAttachedActors()).toEqual({})
	domain.callbacks[firstActor]()
	domain.callbacks[secondActor]()
	expect(publication:CaptureBaseline(firstActor)).toBeNil()
end)

it("keeps a duplicate attachment idempotent and refuses attachment after destruction", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 1)
	local publication: ServerNetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
	runtime = publication
	expect(publication:AttachActor(actor)).toBe(true)
	expect(publication:AttachActor(actor)).toBe(true)
	expect(domain.snapshotCalls).toBe(1)
	publication:DetachActor(actor)
	expect(domain.disconnectCalls).toBe(1)
	expect(publication:GetActorSequence(actor)).toBe(0)
	publication:Destroy()
	local attached: boolean, reason: string? = publication:AttachActor(actor)
	expect(attached).toBe(false)
	expect(reason).toBe("PublicationRuntimeDestroyed")
end)

it("rejects a yielding live snapshot synchronously and preserves the last valid baseline", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 1)
	local shouldYield: boolean = false
	domain.definition.snapshot = function(): any
		if shouldYield then
			coroutine.yield()
		end
		return domain.value
	end
	local faults: { ServerNetworkingTypes.PublicationFault } = {}
	local publication: ServerNetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition }, {
		ReportFault = function(fault: ServerNetworkingTypes.PublicationFault): ()
			table.insert(faults, fault)
		end,
	})
	runtime = publication
	expect(publication:AttachActor(actor)).toBe(true)
	shouldYield = true
	domain.value = 2
	local accepted: boolean? = nil
	local thread: thread = coroutine.create(function(): ()
		accepted = pcall(function(): ()
			domain.callbacks[actor]()
		end)
	end)
	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
	expect(accepted).toBe(false)
	expect(publication:CaptureBaseline(actor)).toEqual({
		sequence = 0,
		domains = { ["Game.State"] = { value = 1 } },
	})
	expect(faults[#faults]).toEqual({
		actorId = actor:GetId(),
		domainId = "Game.State",
		reason = "PublicationSnapshotYielded",
	})
	shouldYield = false
	domain.callbacks[actor]()
	expect(publication:GetActorSequence(actor)).toBe(1)
end)
