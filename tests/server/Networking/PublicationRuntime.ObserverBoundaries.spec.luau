--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local runtime: NetworkingTypes.PublicationRuntime? = nil

afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
end)

it("skips disconnected commit subscriptions, defers new observers, and completes delivery after failure", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 0)
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
	runtime = publication
	local order: { string } = {}
	local disconnectSecond: () -> () = function(): () end
	local first: boolean = true
	local original = { reason = "ObserverFailure" }

	publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
		table.insert(order, `First:{commit.sequence}`)

		if first then
			first = false
			disconnectSecond()
			disconnectSecond()

			publication:ObserveCommits(function(nextCommit: NetworkingTypes.PublicationCommit): ()
				table.insert(order, `New:{nextCommit.sequence}`)
			end)

			domain.value = 2
			domain.callbacks[actor]()
			error(original, 0)
		end
	end)

	disconnectSecond = publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
		table.insert(order, `Disconnected:{commit.sequence}`)
	end)

	publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
		table.insert(order, `Healthy:{commit.sequence}`)
	end)

	expect(publication:AttachActor(actor)).toBe(true)
	domain.value = 1
	local success: boolean, failure: any = pcall(domain.callbacks[actor], nil)
	expect(success).toBe(false)
	expect(failure).toBe(original)
	expect(order).toEqual({ "First:1", "Healthy:1", "First:2", "Healthy:2", "New:2" })
	expect(publication:CaptureBaseline(actor)).toEqual({ sequence = 2, domains = { ["Game.State"] = { value = 2 } } })
	domain.value = 3
	domain.callbacks[actor]()
	expect(publication:GetActorSequence(actor)).toBe(3)
	expect(order[6]).toBe("First:3")
	expect(order[7]).toBe("Healthy:3")
	expect(order[8]).toBe("New:3")
end)

it("disconnects the exact registration when the same publication callback is subscribed twice", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 0)
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
	runtime = publication
	local calls: number = 0
	local disconnectSecond: () -> () = function(): () end

	publication:ObserveCommits(function(): ()
		disconnectSecond()
	end)

	local function callback(): ()
		calls += 1
	end

	local disconnectFirst: () -> () = publication:ObserveCommits(callback)
	disconnectSecond = publication:ObserveCommits(callback)
	expect(publication:AttachActor(actor)).toBe(true)
	domain.value = 1
	domain.callbacks[actor]()
	expect(calls).toBe(1)
	disconnectFirst()
	domain.value = 2
	domain.callbacks[actor]()
	expect(calls).toBe(1)
end)

for _, boundary: string in { "Detach", "FailedAttachment", "FaultReporter" } do
	it(`does not let a yielding {boundary} callback suspend N3 cleanup or recovery`, function()
		local actor: ActorTypes.Actor = ActorEntity.new()
		local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 0)
		local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 0)
		local shouldYield: boolean = true
		local suspended: thread? = nil
		local resumed: boolean = false

		local function yielding(): ()
			if shouldYield then
				suspended = coroutine.running()
				coroutine.yield()
				resumed = true
			end
		end

		if boundary ~= "FaultReporter" then
			first.definition.observe = function(): () -> ()
				return yielding
			end
		end

		local publication: NetworkingTypes.PublicationRuntime = TestUtils.createRuntime(
			{ first.definition, second.definition },
			{
				ReportFault = if boundary == "FaultReporter" then yielding else nil,
			}
		)

		runtime = publication
		local failure: any = nil
		local attached: boolean? = nil

		if boundary ~= "FailedAttachment" then
			expect(publication:AttachActor(actor)).toBe(true)
		else
			second.value = 256
		end

		local transaction: thread = coroutine.create(function(): ()
			if boundary == "Detach" then
				publication:DetachActor(actor)
			elseif boundary == "FailedAttachment" then
				attached, failure = publication:AttachActor(actor)
			else
				first.value = 256

				local _success: boolean
				_success, failure = pcall(first.callbacks[actor], nil)
			end
		end)

		expect(coroutine.resume(transaction)).toBe(true)
		local status: string = coroutine.status(transaction)

		if status ~= "dead" then
			coroutine.close(transaction)
		end

		expect(status).toBe("dead")
		assert(suspended ~= nil, "Expected callback to attempt yielding")
		expect(coroutine.status(suspended)).toBe("dead")
		expect(resumed).toBe(false)
		shouldYield = false

		if boundary == "FaultReporter" then
			expect(failure).toBe("InvalidPublicationSnapshot:Game.A")
			expect(publication:GetActorSequence(actor)).toBe(0)
			first.value = 1
			first.callbacks[actor]()
			expect(publication:GetActorSequence(actor)).toBe(1)
		else
			expect(publication:GetAttachedActors()).toEqual({})
			expect(publication:CaptureBaseline(actor)).toBeNil()

			if boundary == "Detach" then
				expect(second.disconnectCalls).toBe(1)
			else
				expect(attached).toBe(false)
				expect(failure).toBe("InvalidPublicationSnapshot:Game.B")
			end

			second.value = 0
			expect(publication:AttachActor(actor)).toBe(true)
			second.value = 1
			second.callbacks[actor]()
			expect(publication:GetActorSequence(actor)).toBe(1)
		end
	end)
end

for _, original: { name: string, value: any } in
	{ { name = "table", value = {} }, { name = "false", value = false }, { name = "nil" } }
do
	for _, observerFailure: string in { "Throw", "Yield" } do
		it(
			`preserves the original {original.name} authoritative error after admitted observer {observerFailure}`,
			function()
				local actor: ActorTypes.Actor = ActorEntity.new()
				local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 0)
				local publication: NetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
				runtime = publication
				expect(publication:AttachActor(actor)).toBe(true)
				local commits: { NetworkingTypes.PublicationCommit } = {}

				local disconnect: () -> () = publication:ObserveCommits(function(): ()
					if observerFailure == "Throw" then
						error("LaterObserverFailure", 0)
					end

					coroutine.yield()
				end)

				publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
					table.insert(commits, commit)
				end)

				local success: boolean, failure: any = pcall(function(): ()
					publication:WithActorCommit(actor, function(): ()
						domain.value = 1
						domain.callbacks[actor]()
						error(original.value, 0)
					end)
				end)

				expect(success).toBe(false)
				expect(failure).toBe(original.value)
				expect(#commits).toBe(1)

				expect(publication:CaptureBaseline(actor)).toEqual({
					sequence = 1,
					domains = { ["Game.State"] = { value = 1 } },
				})

				disconnect()
				domain.value = 2
				domain.callbacks[actor]()
				expect(#commits).toBe(2)
				expect(commits[2].sequence).toBe(2)
			end
		)
	end
end

it("keeps rejected producer snapshots above ordinary authoritative errors in group failure precedence", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local domain: TestUtils.DomainFixture = TestUtils.createDomain("Game.State", Schema.U8, 0)
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.createRuntime({ domain.definition })
	runtime = publication
	expect(publication:AttachActor(actor)).toBe(true)

	local success: boolean, failure: any = pcall(function(): ()
		publication:WithActorCommit(actor, function(): ()
			domain.value = 256
			domain.callbacks[actor]()
			error("AuthoritativeFailure", 0)
		end)
	end)

	expect(success).toBe(false)
	expect(failure).toBe("InvalidPublicationSnapshot:Game.State")
	expect(publication:CaptureBaseline(actor)).toEqual({ sequence = 0, domains = { ["Game.State"] = { value = 0 } } })
	domain.value = 1
	domain.callbacks[actor]()
	expect(publication:GetActorSequence(actor)).toBe(1)
end)

for _, throwsAfterReport: boolean in { false, true } do
	it(
		`retains the first malformed-event failure through caught reports, later authority error={throwsAfterReport}`,
		function()
			local actor: ActorTypes.Actor = ActorEntity.new()
			local first: TestUtils.DomainFixture = TestUtils.createDomain("Game.A", Schema.U8, 0)
			local second: TestUtils.DomainFixture = TestUtils.createDomain("Game.B", Schema.U8, 0)

			local publication: NetworkingTypes.PublicationRuntime =
				TestUtils.createRuntime({ first.definition, second.definition })

			runtime = publication
			expect(publication:AttachActor(actor)).toBe(true)
			local commits: { NetworkingTypes.PublicationCommit } = {}

			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
				table.insert(commits, commit)
			end)

			local success: boolean, failure: any = pcall(function(): ()
				publication:WithActorCommit(actor, function(): ()
					first.value = 1
					second.value = 2

					local invalidReport: { ReplicationTypes.ReplicationDomainEvent } =
						{ { id = "Unknown", payload = 1 } }

					local firstAccepted: boolean = pcall(first.callbacks[actor], invalidReport)
					local secondAccepted: boolean = pcall(second.callbacks[actor], invalidReport)
					expect(firstAccepted).toBe(false)
					expect(secondAccepted).toBe(false)

					if throwsAfterReport then
						error("LaterAuthoritativeFailure", 0)
					end
				end)
			end)

			expect(success).toBe(false)
			expect(failure).toBe("InvalidPublicationEvent:Game.A")
			expect(publication:GetActorSequence(actor)).toBe(0)
			expect(commits).toEqual({})

			expect(publication:CaptureBaseline(actor)).toEqual({
				sequence = 0,
				domains = { ["Game.A"] = { value = 0 }, ["Game.B"] = { value = 0 } },
			})

			second.callbacks[actor]()
			expect(#commits).toBe(1)
			expect(commits[1].sequence).toBe(1)
			expect(#commits[1].patches).toBe(2)
			expect(commits[1].events).toEqual({})
		end
	)
end
