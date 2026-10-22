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
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local actor: ActorTypes.Actor
local resource: TestUtils.DomainFixture
local action: TestUtils.DomainFixture
local runtime: ServerNetworkingTypes.PublicationRuntime
local commits: { ServerNetworkingTypes.PublicationCommit } = {}

beforeEach(function()
	actor = ActorEntity.new()
	resource = TestUtils.createDomain("Game.Resource", Schema.U8, 100)
	action = TestUtils.createDomain("Game.Action", Schema.Boolean, false)
	resource.definition.events = { { id = "Spent", payload = Schema.Struct({ amount = Schema.U8 }) } }
	action.definition.events = { { id = "Started", payload = Schema.Struct({}) } }
	commits = {}
	runtime = TestUtils.createRuntime({ resource.definition, action.definition })
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

it("seals two domains as one coherent commit and captures each only once at close", function()
	attach()

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 80
		resource.callbacks[actor]()
		resource.value = 60
		resource.callbacks[actor]()
		action.value = true
		action.callbacks[actor]()
		expect(resource.snapshotCalls).toBe(1)
		expect(action.snapshotCalls).toBe(1)
		expect(#commits).toBe(0)
	end)

	expect(resource.snapshotCalls).toBe(2)
	expect(action.snapshotCalls).toBe(2)
	expect(#commits).toBe(1)
	expect(commits[1].sequence).toBe(1)
	local patchesByDomain: { [string]: ServerNetworkingTypes.PublicationPatch } = {}

	for _, patch: ServerNetworkingTypes.PublicationDomainPatch in commits[1].patches do
		patchesByDomain[patch.domainId] = patch.patch
	end

	expect(patchesByDomain).toEqual({
		["Game.Resource"] = { kind = "Replace", value = 60 },
		["Game.Action"] = { kind = "Replace", value = true },
	})

	expect(runtime:CaptureBaseline(actor)).toEqual({
		sequence = 1,
		domains = { ["Game.Resource"] = { value = 60 }, ["Game.Action"] = { value = true } },
	})
end)

it("captures grouped event payloads at report time and preserves cross-domain report order", function()
	attach()
	local payload: any = { amount = 20 }

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 80
		resource.callbacks[actor]({ { id = "Spent", payload = payload } })
		payload.amount = 99
		action.value = true
		action.callbacks[actor]({ { id = "Started", payload = {} } })
		resource.value = 60
		resource.callbacks[actor]({ { id = "Spent", payload = { amount = 20 } } })
	end)

	expect(commits[1].events).toEqual({
		{ domainId = "Game.Resource", eventId = "Spent", payload = { amount = 20 } },
		{ domainId = "Game.Action", eventId = "Started", payload = {} },
		{ domainId = "Game.Resource", eventId = "Spent", payload = { amount = 20 } },
	})

	expect(resource.snapshotCalls).toBe(2)
end)

it("joins nested same-Actor groups and leaves untouched domains uncaptured", function()
	attach()

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 90
		resource.callbacks[actor]()

		runtime:WithActorCommit(actor, function(): ()
			resource.value = 80
			resource.callbacks[actor]()
		end)

		expect(#commits).toBe(0)
		expect(resource.snapshotCalls).toBe(1)
	end)

	expect(#commits).toBe(1)
	expect(resource.snapshotCalls).toBe(2)
	expect(action.snapshotCalls).toBe(1)
end)

it("does not merge independent Actor groups into cross-Actor atomicity", function()
	attach()
	local otherActor: ActorTypes.Actor = ActorEntity.new()
	expect(runtime:AttachActor(otherActor)).toBe(true)

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 90
		resource.callbacks[actor]()

		runtime:WithActorCommit(otherActor, function(): ()
			resource.value = 80
			resource.callbacks[otherActor]()
		end)

		expect(#commits).toBe(1)
		expect(commits[1].actor).toBe(otherActor)
	end)

	expect(#commits).toBe(2)
	expect(commits[2].actor).toBe(actor)
	expect(commits[1].sequence).toBe(1)
	expect(commits[2].sequence).toBe(1)
end)

it("does not allocate a sequence for an empty group or a group returning to its original truth", function()
	attach()
	runtime:WithActorCommit(actor, function(): () end)

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 90
		resource.callbacks[actor]()
		resource.value = 100
		resource.callbacks[actor]()
	end)

	expect(commits).toEqual({})
	expect(runtime:GetActorSequence(actor)).toBe(0)
end)

it("dispatches a group only after all canonical domains and its sequence are committed", function()
	attach()
	local observed: ServerNetworkingTypes.PublicationBaseline? = nil

	runtime:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		observed = runtime:CaptureBaseline(actor)

		expect(observed).toEqual({
			sequence = commit.sequence,
			domains = { ["Game.Resource"] = { value = 80 }, ["Game.Action"] = { value = true } },
		})
	end)

	runtime:WithActorCommit(actor, function(): ()
		resource.value = 80
		resource.callbacks[actor]()
		action.value = true
		action.callbacks[actor]({ { id = "Started", payload = {} } })
	end)

	expect(observed).toEqual({
		sequence = 1,
		domains = { ["Game.Resource"] = { value = 80 }, ["Game.Action"] = { value = true } },
	})
end)

it("unwinds an errored group, reconciles reported mutations and preserves the original error", function()
	attach()
	local originalFailure: any = { message = "AuthoritativeMutationFailed" }

	local success: boolean, failure: any = pcall(function(): ()
		runtime:WithActorCommit(actor, function(): ()
			resource.value = 80
			resource.callbacks[actor]()
			error(originalFailure, 0)
		end)
	end)

	expect(success).toBe(false)
	expect(failure).toBe(originalFailure)
	expect(#commits).toBe(1)

	expect(runtime:CaptureBaseline(actor)).toEqual({
		sequence = 1,
		domains = { ["Game.Resource"] = { value = 80 }, ["Game.Action"] = { value = false } },
	})

	resource.value = 60
	resource.callbacks[actor]()
	expect(#commits).toBe(2)
	expect(commits[2].sequence).toBe(2)
end)

it("rejects the whole grouped publication when one final snapshot is invalid", function()
	attach()

	local success: boolean = pcall(function(): ()
		runtime:WithActorCommit(actor, function(): ()
			resource.value = 80
			resource.callbacks[actor]()
			action.value = "invalid"
			action.callbacks[actor]()
		end)
	end)

	expect(success).toBe(false)
	expect(commits).toEqual({})

	expect(runtime:CaptureBaseline(actor)).toEqual({
		sequence = 0,
		domains = { ["Game.Resource"] = { value = 100 }, ["Game.Action"] = { value = false } },
	})

	-- Retrying an unrelated participant must not drop the rejected group when
	-- its sibling is still invalid, or publish a partial canonical state.
	resource.value = 60
	expect((pcall(resource.callbacks[actor], nil))).toBe(false)
	expect(runtime:GetActorSequence(actor)).toBe(0)
	expect(commits).toEqual({})
	action.value = true

	runtime:WithActorCommit(actor, function(): ()
		action.callbacks[actor]()
	end)

	expect(commits[1].sequence).toBe(1)
	expect(#commits[1].patches).toBe(2)
	local recovered: ServerNetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
	assert(recovered ~= nil, "Expected retained Actor publication")
	expect(recovered.domains["Game.Resource"].value).toBe(60)
end)

for _, invalidReport: { name: string, events: any } in
	{
		{ name = "unknown event", events = { { id = "Unknown", payload = {} } } },
		{
			name = "sparse event array",
			events = { [1] = { id = "Started", payload = {} }, [3] = { id = "Started", payload = {} } },
		},
	}
do
	it("rejects a grouped " .. invalidReport.name .. " without leaking another touched domain's state", function()
		-- Issue #73 decisions 15 and 40 now give producer contract violations
		-- precedence over ordinary authoritative callback error reconciliation.
		attach()

		local success: boolean = pcall(function(): ()
			runtime:WithActorCommit(actor, function(): ()
				resource.value = 80
				resource.callbacks[actor]()
				action.callbacks[actor](invalidReport.events)
			end)
		end)

		expect(success).toBe(false)
		expect(commits).toEqual({})
		expect(runtime:GetActorSequence(actor)).toBe(0)
		local captured: ServerNetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
		assert(captured ~= nil, "Expected existing canonical baseline")
		expect(captured.domains["Game.Resource"].value).toBe(100)
		resource.callbacks[actor]()
		expect(commits[1].sequence).toBe(1)
	end)
end

it("treats reentrant authoritative work from a commit observer as the next standalone commit", function()
	attach()

	runtime:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		if commit.sequence == 1 then
			action.value = false
			action.callbacks[actor]()
		end
	end)

	runtime:WithActorCommit(actor, function(): ()
		action.value = true
		action.callbacks[actor]()
	end)

	expect(#commits).toBe(2)
	expect(commits[1].patches).toEqual({ { domainId = "Game.Action", patch = { kind = "Replace", value = true } } })
	expect(commits[2].patches).toEqual({ { domainId = "Game.Action", patch = { kind = "Replace", value = false } } })
	expect(commits[2].sequence).toBe(2)
end)

it("delivers reentrant commits in Actor sequence order to every observer", function()
	attach()
	local laterObserverSequences: { number } = {}

	runtime:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		if commit.sequence == 1 then
			action.value = false
			action.callbacks[actor]()
		end
	end)

	runtime:ObserveCommits(function(commit: ServerNetworkingTypes.PublicationCommit): ()
		table.insert(laterObserverSequences, commit.sequence)
	end)

	action.value = true
	action.callbacks[actor]()
	expect(laterObserverSequences).toEqual({ 1, 2 })
	expect(runtime:GetActorSequence(actor)).toBe(2)
end)

it("closes a yielding callback so scheduled work cannot resume after rejection", function()
	attach()
	local resumedAfterYield: boolean = false

	local accepted: boolean = pcall(function(): ()
		runtime:WithActorCommit(actor, function(): ()
			task.wait(0.01)
			resumedAfterYield = true
		end)
	end)

	expect(accepted).toBe(false)
	task.wait(0.05)
	expect(resumedAfterYield).toBe(false)
	action.value = true
	action.callbacks[actor]()
	expect(runtime:GetActorSequence(actor)).toBe(1)
end)

it("returns from valid grouped capture without yielding", function()
	attach()

	local thread: thread = coroutine.create(function(): ()
		runtime:WithActorCommit(actor, function(): ()
			resource.value = 80
			resource.callbacks[actor]()
		end)
	end)

	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
	expect(#commits).toBe(1)
end)

it("rejects a yielding grouped callback synchronously and leaves later publication ungrouped", function()
	attach()
	local completed: boolean? = nil
	local failure: any = nil

	local thread: thread = coroutine.create(function(): ()
		completed, failure = pcall(function(): ()
			runtime:WithActorCommit(actor, function(): ()
				resource.value = 80
				resource.callbacks[actor]()
				coroutine.yield()
			end)
		end)
	end)

	expect(coroutine.resume(thread)).toBe(true)
	expect(coroutine.status(thread)).toBe("dead")
	expect(completed).toBe(false)
	expect(string.find(tostring(failure), "Yield", 1, true) ~= nil).toBe(true)
	local priorCommits: number = #commits

	resource.value = 60
	resource.callbacks[actor]()
	expect(#commits).toBe(priorCommits + 1)

	expect(commits[#commits].patches).toEqual({
		{ domainId = "Game.Resource", patch = { kind = "Replace", value = 60 } },
	})

	expect(runtime:CaptureBaseline(actor)).toEqual({
		sequence = #commits,
		domains = { ["Game.Resource"] = { value = 60 }, ["Game.Action"] = { value = false } },
	})
end)

it("enforces the non-yield contract before an Actor is attached", function()
	local completed: boolean, failure: any = pcall(function(): ()
		runtime:WithActorCommit(actor, function(): ()
			coroutine.yield()
		end)
	end)

	expect(completed).toBe(false)
	expect(string.find(tostring(failure), "Yield", 1, true) ~= nil).toBe(true)
	attach()
	resource.value = 80
	resource.callbacks[actor]()
	expect(commits[1].sequence).toBe(1)
end)
