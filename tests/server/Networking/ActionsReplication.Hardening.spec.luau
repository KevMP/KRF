--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Scheduler: NetworkingTypes.PublicationSchedulerModule = require(KRF.server.Networking.utils.PublicationScheduler)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local publication: NetworkingTypes.PublicationRuntime? = nil
local scheduler: NetworkingTypes.PublicationScheduler? = nil
beforeEach(ActionUtils.reset)

afterEach(function()
	if publication ~= nil then
		publication:Destroy()
		publication = nil
	end

	if scheduler ~= nil then
		scheduler:Destroy()
		scheduler = nil
	end

	ActionUtils.cleanup()
end)

it(
	"never publishes a sibling domain or earlier valid Action entry when a later mutation makes the group invalid",
	function()
		TestUtils.initialize({ TestUtils.action("Visible") })
		local definition: ReplicationTypes.ReplicationDomainDefinition = TestUtils.build()
		local actor: ActorTypes.Actor = ActorEntity.new()
		local callback: (({ TestUtils.Mutation }) -> ())? = nil

		expect(actor:SetController("ActionController", {
			Destroy = function() end,
			_getActiveReplicationState = function(): { TestUtils.Identity }
				return {}
			end,
			_observeMutations = function(_self: any, observer: ({ TestUtils.Mutation }) -> ()): () -> ()
				callback = observer

				return function() end
			end,
		})).toBe(true)

		local sibling: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Counter", Schema.U8, 1)
		local faults: { NetworkingTypes.PublicationFault } = {}

		local runtime: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime(
			{ definition, sibling.definition },
			{
				ReportFault = function(fault: NetworkingTypes.PublicationFault)
					table.insert(faults, fault)
				end,
			}
		)

		publication = runtime
		expect(runtime:AttachActor(actor)).toBe(true)
		local previous: NetworkingTypes.PublicationBaseline? = runtime:CaptureBaseline(actor)
		local commits: { NetworkingTypes.PublicationCommit } = {}

		runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
			table.insert(commits, commit)
		end)

		assert(callback ~= nil, "Expected N8 private observer installation")
		local mutate: ({ TestUtils.Mutation }) -> () = callback

		local completed: boolean = pcall(function()
			runtime:WithActorCommit(actor, function()
				sibling.value = 2
				sibling.callbacks[actor]()

				mutate({
					{ kind = "Started", actionId = "Visible", sequenceId = 1 },
					{ kind = "Started", actionId = "Visible", sequenceId = 4294967296 },
				})
			end)
		end)

		expect(completed).toBe(false)
		expect(commits).toEqual({})
		expect(runtime:GetActorSequence(actor)).toBe(0)
		expect(runtime:CaptureBaseline(actor)).toEqual(previous)
		expect(#faults).toBe(1)
		expect(faults[1].domainId).toBe("KRF.Actions")
	end
)

it("lets N3 bound lifecycle backlog and recover current truth without replaying discarded Starts", function()
	TestUtils.initialize({ TestUtils.action("Visible"), TestUtils.action("Private", "ServerOnly") })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	TestUtils.domain()
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

	for _ = 1, 3 do
		TestUtils.accept(actions, "Visible")
	end

	TestUtils.accept(actions, "Private")
	expect(#commits).toBe(3)

	local queue: NetworkingTypes.PublicationScheduler = Scheduler.new({
		maxBarriers = 8,
		maxEvents = 2,
		maxQueuedBytes = 1024,
		MeasureRecord = function(): number
			return 16
		end,
	})

	scheduler = queue
	local stream: NetworkingTypes.PublicationStreamKey = { recipient = "Client", actor = actor }

	for index: number = 1, 2 do
		local commit: NetworkingTypes.PublicationCommit = commits[index]

		expect(queue:Enqueue(stream, { sequence = commit.sequence, patches = commit.patches, events = commit.events })).toBe(
			true
		)
	end

	local third: NetworkingTypes.PublicationCommit = commits[3]

	local accepted: boolean, reason: string? =
		queue:Enqueue(stream, { sequence = third.sequence, patches = third.patches, events = third.events })

	expect(accepted).toBe(false)
	expect(reason).toBe("PublicationStreamOverloaded")

	expect(queue:GetStreamStatus(stream)).toEqual({
		needsBaseline = true,
		pendingRecords = 0,
		pendingEvents = 0,
		queuedBytes = 0,
	})

	expect(queue:DrainBudgeted(1024, 8).records).toEqual({})
	local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(baseline ~= nil, "Expected replacement current truth")
	expect(baseline.domains["KRF.Actions"].value).toEqual({ [1] = "Visible", [2] = "Visible", [3] = "Visible" })
	queue:ResetAfterBaseline(stream, baseline.domains)
	expect(actions:EndAction(2)).toBe(true)
	local terminal: NetworkingTypes.PublicationCommit = commits[4]

	expect(
		queue:Enqueue(stream, { sequence = terminal.sequence, patches = terminal.patches, events = terminal.events })
	).toBe(true)

	local drained: NetworkingTypes.PublicationDrainResult = queue:DrainBudgeted(1024, 8)
	expect(#drained.records).toBe(1)

	expect(drained.records[1].commit.events).toEqual({
		{ domainId = "KRF.Actions", eventId = "Ended", payload = { actionId = "Visible", sequenceId = 2 } },
	})
end)

it("closes Started before a public listener can synchronously end the accepted instance", function()
	TestUtils.initialize({ TestUtils.action("Visible") })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	local observedBeforeReentry: { number } = {}

	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		table.insert(observedBeforeReentry, #commits)
		actions:EndAction(event.sequenceId)
	end)

	TestUtils.accept(actions, "Visible")
	expect(observedBeforeReentry).toEqual({ 1 })
	expect(#commits).toBe(2)

	expect(TestUtils.events(commits[1])).toEqual({
		{ domainId = "KRF.Actions", eventId = "Started", payload = { actionId = "Visible", sequenceId = 1 } },
	})

	expect(TestUtils.events(commits[2])).toEqual({
		{ domainId = "KRF.Actions", eventId = "Ended", payload = { actionId = "Visible", sequenceId = 1 } },
	})

	expect(TestUtils.state(actor)).toEqual({})
end)
