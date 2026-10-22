--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local actor: ActorTypes.Actor
local domains: { TestUtils.DomainFixture }
local runtime: NetworkingTypes.PublicationRuntime
local commits: { NetworkingTypes.PublicationCommit }

beforeEach(function()
	actor = ActorEntity.new()
	domains = {}
	local definitions: { ReplicationTypes.ReplicationDomainDefinition } = {}

	for _, id: string in { "Game.A", "Game.B", "Game.C", "Game.D" } do
		local domain: TestUtils.DomainFixture = TestUtils.createDomain(id, Schema.U8, 0)
		domain.definition.events = { { id = "Changed", payload = Schema.U8 } }
		table.insert(domains, domain)
		table.insert(definitions, domain.definition)
	end

	runtime = TestUtils.createRuntime(definitions)
	commits = {}

	runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(commits, commit)
	end)

	expect(runtime:AttachActor(actor)).toBe(true)
end)

afterEach(function()
	runtime:Destroy()
end)

local function report(index: number, value: any): ()
	domains[index].value = value
	domains[index].callbacks[actor]({ { id = "Changed", payload = index } })
end

local function truth(): { [string]: any }
	local baseline: NetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
	assert(baseline ~= nil, "Expected attached publication")
	local values: { [string]: any } = {}

	for id: string, domain in baseline.domains do
		values[id] = domain.value
	end

	return values
end

for _, failureKind: string in { "invalid", "throw", "yield" } do
	it("isolates persistent " .. failureKind .. " snapshots while retaining atomic recovery dependencies", function()
		local failing: boolean = true
		local resumed: boolean = false
		local captureAttempts: number = 0
		local snapshot = domains[1].definition.snapshot
		-- Prepared definitions retain the callback supplied before runtime creation.
		runtime:Destroy()

		domains[1].definition.snapshot = function(target: ActorTypes.Actor): any
			captureAttempts += 1

			if failing then
				if failureKind == "throw" then
					error("PersistentSnapshotFailure", 0)
				elseif failureKind == "yield" then
					task.wait(0.01)
					resumed = true
				end

				return "invalid"
			end

			return snapshot(target)
		end

		failing = false

		runtime = TestUtils.createRuntime({
			domains[1].definition,
			domains[2].definition,
			domains[3].definition,
			domains[4].definition,
		})

		runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
			table.insert(commits, commit)
		end)

		expect(runtime:AttachActor(actor)).toBe(true)
		failing = true

		local expectedFailure: string = if failureKind == "invalid"
			then "InvalidPublicationSnapshot:Game.A"
			else "PublicationSnapshot" .. (if failureKind == "throw" then "Error" else "Yielded") .. ":Game.A"

		local completed: boolean, failure: any = pcall(function()
			runtime:WithActorCommit(actor, function()
				report(1, 10)
				report(2, 20)
			end)
		end)

		expect(completed).toBe(false)
		expect(failure).toBe(expectedFailure)

		for attempt: number = 1, 3 do
			-- A healthy member cannot escape its failed atomic group.
			local retried: boolean, retryFailure: any = pcall(report, 2, 20 + attempt)
			expect(retried).toBe(false)
			expect(retryFailure).toBe(expectedFailure)
			local before: number = captureAttempts

			if attempt == 2 then
				runtime:WithActorCommit(actor, function()
					runtime:WithActorCommit(actor, function()
						report(3, attempt)
					end)
				end)
			else
				report(3, attempt)
			end

			expect(captureAttempts).toBe(before)
			expect(commits[attempt].sequence).toBe(attempt)
			expect(commits[attempt].events).toEqual({ { domainId = "Game.C", eventId = "Changed", payload = 3 } })
			expect(truth()).toEqual({ ["Game.A"] = 0, ["Game.B"] = 0, ["Game.C"] = attempt, ["Game.D"] = 0 })
		end

		failing = false
		report(1, 11)
		expect(truth()).toEqual({ ["Game.A"] = 11, ["Game.B"] = 23, ["Game.C"] = 3, ["Game.D"] = 0 })
		expect(#commits[4].patches).toBe(2)
		expect(commits[4].events).toEqual({ { domainId = "Game.A", eventId = "Changed", payload = 1 } })
		task.wait(0.03)
		expect(resumed).toBe(false)
	end)
end

it("recovers disjoint failed groups independently without losing either group's pending truth", function()
	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(1, "invalid")
			report(2, "invalid")
		end)
	end))).toBe(false)

	-- Correcting one participant is insufficient until its sibling also recovers.
	expect((pcall(report, 2, 20))).toBe(false)
	expect(runtime:GetActorSequence(actor)).toBe(0)

	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(3, "invalid")
			report(4, 40)
		end)
	end))).toBe(false)

	report(1, 10)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 20, ["Game.C"] = 0, ["Game.D"] = 0 })
	expect(commits[1].sequence).toBe(1)
	expect(#commits[1].patches).toBe(2)
	expect((pcall(report, 4, 41))).toBe(false)
	report(3, 30)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 20, ["Game.C"] = 30, ["Game.D"] = 41 })
	expect(commits[2].sequence).toBe(2)
	expect(#commits[2].patches).toBe(2)
	expect(commits[2].events).toEqual({ { domainId = "Game.C", eventId = "Changed", payload = 3 } })
end)

it("retains grouped truth after malformed events without replaying the rejected event history", function()
	local completed: boolean, failure: any = pcall(function()
		runtime:WithActorCommit(actor, function()
			report(1, 10)
			domains[2].value = 20
			domains[2].callbacks[actor]({ { id = "Unknown", payload = 2 } })
		end)
	end)

	expect(completed).toBe(false)
	expect(failure).toBe("InvalidPublicationEvent:Game.B")
	expect(commits).toEqual({})
	expect(truth()).toEqual({ ["Game.A"] = 0, ["Game.B"] = 0, ["Game.C"] = 0, ["Game.D"] = 0 })
	report(3, 30)
	expect(#commits[1].patches).toBe(1)
	expect(truth()).toEqual({ ["Game.A"] = 0, ["Game.B"] = 0, ["Game.C"] = 30, ["Game.D"] = 0 })
	report(2, 21)
	expect(#commits[2].patches).toBe(2)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 21, ["Game.C"] = 30, ["Game.D"] = 0 })
	expect(commits[2].events).toEqual({ { domainId = "Game.B", eventId = "Changed", payload = 2 } })
end)

it("joins overlapping recovery dependencies through nested transactions without partially admitting them", function()
	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(1, "invalid")
			report(2, 20)
		end)
	end))).toBe(false)

	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(2, 21)

			runtime:WithActorCommit(actor, function()
				report(3, 30)
			end)
		end)
	end))).toBe(false)

	expect((pcall(report, 3, 31))).toBe(false)
	report(4, 40)
	expect(truth()).toEqual({ ["Game.A"] = 0, ["Game.B"] = 0, ["Game.C"] = 0, ["Game.D"] = 40 })
	report(1, 10)
	expect(#commits[2].patches).toBe(3)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 21, ["Game.C"] = 31, ["Game.D"] = 40 })
	expect(commits[2].events).toEqual({ { domainId = "Game.A", eventId = "Changed", payload = 1 } })
end)

it("retires failed recovery and an open transaction on detach without publishing into a reattachment", function()
	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(1, "invalid")
			report(2, 20)
		end)
	end))).toBe(false)

	local stale = domains[2].callbacks[actor]

	domains[1].value = 10

	runtime:WithActorCommit(actor, function()
		report(2, 21)
		runtime:DetachActor(actor)
		expect(runtime:AttachActor(actor)).toBe(true)
		stale()
	end)

	expect(commits).toEqual({})
	expect(runtime:GetActorSequence(actor)).toBe(0)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 21, ["Game.C"] = 0, ["Game.D"] = 0 })
	report(4, 40)
	expect(commits[1].sequence).toBe(1)
	expect(#commits[1].patches).toBe(1)
end)

it("joins two disjoint recovery groups only when a later nested transaction touches both", function()
	for _, first: number in { 1, 3 } do
		expect((pcall(function()
			runtime:WithActorCommit(actor, function()
				report(first, "invalid")
				report(first + 1, first * 10)
			end)
		end))).toBe(false)
	end

	expect((pcall(function()
		runtime:WithActorCommit(actor, function()
			report(2, 20)

			runtime:WithActorCommit(actor, function()
				report(3, 30)
			end)
		end)
	end))).toBe(false)

	expect(commits).toEqual({})
	expect((pcall(report, 4, 40))).toBe(false)
	report(1, 10)
	expect(#commits).toBe(1)
	expect(#commits[1].patches).toBe(4)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 20, ["Game.C"] = 30, ["Game.D"] = 40 })
	expect(commits[1].events).toEqual({ { domainId = "Game.A", eventId = "Changed", payload = 1 } })
end)

it("discards capture results if a producer detaches the Actor during snapshot evaluation", function()
	runtime:Destroy()
	local detaching: boolean = false
	local snapshot = domains[1].definition.snapshot

	domains[1].definition.snapshot = function(target: ActorTypes.Actor): any
		if detaching then
			runtime:DetachActor(target)
		end

		return snapshot(target)
	end

	runtime = TestUtils.createRuntime({ domains[1].definition, domains[2].definition })

	runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(commits, commit)
	end)

	expect(runtime:AttachActor(actor)).toBe(true)
	detaching = true
	report(1, 10)
	expect(commits).toEqual({})
	expect(runtime:CaptureBaseline(actor)).toBeNil()
	detaching = false
	expect(runtime:AttachActor(actor)).toBe(true)
	expect(truth()).toEqual({ ["Game.A"] = 10, ["Game.B"] = 0 })
	report(2, 20)
	expect(commits[1].sequence).toBe(1)
	expect(#commits[1].patches).toBe(1)
end)
