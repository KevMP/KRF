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
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)

local Builder: ReplicationTypes.BuiltInReplicationDomainBuilder =
	require(KRF.server.Replication.BuiltInReplicationDomains)

local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local originalBuild = Builder.Build
local rejectCapture: boolean = false
local actor: ActorTypes.Actor
local actions: ActionTypes.ActionController
local resources: ResourceTypes.ResourceController
local tags: TagTypes.TagController
local publication: NetworkingTypes.PublicationRuntime
local commits: { NetworkingTypes.PublicationCommit } = {}
local contexts: { [number]: ActionTypes.ActionExecutionContext } = {}
local order: { string } = {}
local lifecycleTruth: { any } = {}
local reasons: { string } = {}
local disconnects: { () -> () } = {}
local rejectedAuthority: { any } = {}

beforeEach(function()
	ActionUtils.reset()
	rejectCapture = false
	commits = {}
	contexts = {}
	order = {}
	lifecycleTruth = {}
	reasons = {}
	disconnects = {}
	rejectedAuthority = {}

	Builder.Build = function(
		catalogs: ReplicationTypes.ReplicationDomainBuildCatalogs
	): ({ ReplicationTypes.ReplicationDomainDefinition }?, string?)
		local domains: { ReplicationTypes.ReplicationDomainDefinition }?, reason: string? = originalBuild(catalogs)

		if domains ~= nil then
			for _, domain: ReplicationTypes.ReplicationDomainDefinition in domains do
				if domain.id == "KRF.Tags" then
					local snapshot = domain.snapshot

					domain.snapshot = function(target: ActorTypes.Actor): any
						local current: any = snapshot(target)

						-- Reject only N3 capture, after the real controllers have committed.
						if rejectCapture then
							local active: boolean = actions:RequestStop(1)

							table.insert(rejectedAuthority, {
								active = active,
								mana = resources:GetCurrent("Mana"),
								incoming = tags:HasTag("Incoming"),
							})

							return "InvalidTagsSnapshot"
						end

						return current
					end
				end
			end
		end

		return domains, reason
	end
end)

afterEach(function()
	rejectCapture = false

	for _, disconnect in disconnects do
		disconnect()
	end

	Builder.Build = originalBuild
	ActionUtils.cleanup()
end)

local function setup(): ()
	local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
	incoming.costs = { Mana = 20 }
	incoming.activeTags = { "Incoming" }
	incoming.locks = { "Hands" }

	incoming.onStart = function(context: ActionTypes.ActionExecutionContext)
		contexts[context.sequenceId] = context
		table.insert(order, "StartHook:" .. context.sequenceId)
	end

	incoming.onEnd = function(context: ActionTypes.ActionExecutionContext)
		table.insert(order, "EndHook:" .. context.sequenceId)
	end

	incoming.onInterrupt = function(context: ActionTypes.ActionExecutionContext, reason: string)
		table.insert(reasons, reason)
		table.insert(order, "InterruptHook:" .. context.sequenceId)
	end

	local later: ActionTypes.ActionDefinition = TestUtils.action("Later")
	later.costs = { Mana = 10 }
	later.activeTags = { "OwnerB" }
	later.onStart = incoming.onStart

	local probe: ActionTypes.ActionDefinition = TestUtils.action("Probe", "ServerOnly")
	probe.locks = { "Hands" }
	TestUtils.initialize({ incoming, later, probe })
	actor, actions, resources = ActionUtils.registerActor()
	tags = actor:GetController("TagController") :: TagTypes.TagController
	publication = TestUtils.publication()
	commits = TestUtils.observe()

	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		local active: boolean = actions:RequestStop(event.sequenceId)

		table.insert(lifecycleTruth, {
			kind = "Started",
			sequenceId = event.sequenceId,
			active = active,
			mana = resources:GetCurrent("Mana"),
			incoming = tags:HasTag("Incoming"),
			revision = publication:GetActorSequence(actor),
		})

		table.insert(order, "Started:" .. event.sequenceId)
	end)

	local function terminal(kind: string, event: ActionTypes.ActionLifecycleEvent)
		local context: ActionTypes.ActionExecutionContext? = contexts[event.sequenceId]

		table.insert(lifecycleTruth, {
			kind = kind,
			sequenceId = event.sequenceId,
			active = if context ~= nil then context:IsActive() else nil,
			mana = resources:GetCurrent("Mana"),
			incoming = tags:HasTag("Incoming"),
			revision = publication:GetActorSequence(actor),
		})

		table.insert(order, kind .. ":" .. event.sequenceId)
	end

	actions.OnActionEnded:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		terminal("Ended", event)
	end)

	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		table.insert(reasons, event.reason)
		terminal("Interrupted", event)
	end)

	tags.OnTagAdded:Connect(function(_actor: ActorTypes.Actor, id: string)
		table.insert(order, "TagAdded:" .. id)
	end)

	tags.OnTagRemoved:Connect(function(_actor: ActorTypes.Actor, id: string)
		table.insert(order, "TagRemoved:" .. id)
	end)

	resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(order, `Resource:{change.currentOldValue}->{change.currentNewValue}`)
	end)
end

local function canonical(sequence: number, state: { [number]: string }, mana: number, tagState: any): ()
	local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
	assert(baseline ~= nil, "Expected retained N3 attachment")
	expect(baseline.sequence).toBe(sequence)
	expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(mana)
	expect(baseline.domains["KRF.Tags"].value).toEqual(tagState)
	expect(baseline.domains["KRF.Actions"]).never.toBeNil()
	expect(baseline.domains["KRF.Actions"].value).toEqual(state)
end

local function actionEvent(kind: string, id: string, sequenceId: number): NetworkingTypes.PublicationEvent
	return { domainId = "KRF.Actions", eventId = kind, payload = { actionId = id, sequenceId = sequenceId } }
end

local function expectCommittedStart(revision: number): ()
	expect(resources:GetCurrent("Mana")).toBe(80)
	expect(tags:HasTag("Incoming")).toBe(true)
	expect(actions:RequestAction("Probe")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(order).toEqual({ "Started:1", "TagAdded:Incoming", "Resource:100->80", "StartHook:1" })

	expect(lifecycleTruth).toEqual({
		{ kind = "Started", sequenceId = 1, active = true, mana = 80, incoming = true, revision = revision },
	})

	local context: ActionTypes.ActionExecutionContext? = contexts[1]
	expect(context).never.toBeNil()
	assert(context ~= nil, "Committed activation must still run onStart")
	expect(context:IsActive()).toBe(true)
end

it(
	"retains committed Start authority and delivers notifications/hooks after N3 rejects capture, then reconciles without replay",
	function()
		setup()
		local previous: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
		rejectCapture = true

		local success: boolean, failure: any = pcall(function()
			actions:RequestAction("Incoming")
		end)

		expect(success).toBe(false)
		expect(failure).toBe("InvalidPublicationSnapshot:KRF.Tags")
		expect(rejectedAuthority).toEqual({ { active = true, mana = 80, incoming = true } })
		-- Capture rejection must leave canonical truth old, despite committed authority.
		expect(publication:CaptureBaseline(actor)).toEqual(previous)
		expect(publication:GetActorSequence(actor)).toBe(0)
		expect(commits).toEqual({})
		expectCommittedStart(0)
		rejectCapture = false
		expect(TestUtils.accept(actions, "Later")).toBe(2)
		expect(resources:GetCurrent("Mana")).toBe(70)
		expect(contexts[1]:IsActive()).toBe(true)
		expect(contexts[2]:IsActive()).toBe(true)

		canonical(
			1,
			{ [1] = "Incoming", [2] = "Later" },
			70,
			{ Incoming = { stackCount = 1 }, OwnerB = { stackCount = 1 } }
		)

		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ actionEvent("Started", "Later", 2) })
		local tagEvents: { NetworkingTypes.PublicationEvent } = {}

		for _, event: NetworkingTypes.PublicationEvent in commits[1].events do
			if event.domainId == "KRF.Tags" then
				table.insert(tagEvents, event)
			end
		end

		expect(tagEvents).toEqual({ { domainId = "KRF.Tags", eventId = "Added", payload = "OwnerB" } })

		expect(order).toEqual({
			"Started:1",
			"TagAdded:Incoming",
			"Resource:100->80",
			"StartHook:1",
			"Started:2",
			"TagAdded:OwnerB",
			"Resource:80->70",
			"StartHook:2",
		})
	end
)

it(
	"retains an admitted Start when a downstream N3 observer throws, preserves its error identity and continues dispatch",
	function()
		setup()
		local failureValue = { reason = "N8DownstreamCommitFailure" }
		local delivery: { string } = {}
		local admitted: NetworkingTypes.PublicationBaseline? = nil

		table.insert(
			disconnects,
			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
				table.insert(delivery, "Throw:" .. commit.sequence)
				admitted = publication:CaptureBaseline(actor)
				error(failureValue, 0)
			end)
		)

		table.insert(
			disconnects,
			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
				table.insert(delivery, "After:" .. commit.sequence)
			end)
		)

		local success: boolean, failure: any = pcall(function()
			actions:RequestAction("Incoming")
		end)

		expect(success).toBe(false)
		expect(failure).toBe(failureValue)
		expectCommittedStart(1)
		canonical(1, { [1] = "Incoming" }, 80, { Incoming = { stackCount = 1 } })
		expect(admitted).toEqual(publication:CaptureBaseline(actor))
		expect(delivery).toEqual({ "Throw:1", "After:1" })
		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ actionEvent("Started", "Incoming", 1) })
		disconnects[1]()
		expect(TestUtils.accept(actions, "Later")).toBe(2)

		canonical(
			2,
			{ [1] = "Incoming", [2] = "Later" },
			70,
			{ Incoming = { stackCount = 1 }, OwnerB = { stackCount = 1 } }
		)

		expect(#commits).toBe(2)
		expect(TestUtils.events(commits[2])).toEqual({ actionEvent("Started", "Later", 2) })
		expect(delivery).toEqual({ "Throw:1", "After:1", "After:2" })

		expect(order).toEqual({
			"Started:1",
			"TagAdded:Incoming",
			"Resource:100->80",
			"StartHook:1",
			"Started:2",
			"TagAdded:OwnerB",
			"Resource:80->70",
			"StartHook:2",
		})
	end
)

it(
	"finishes eligible private observers and valid publication before reporting a committed Action observer error",
	function()
		setup()
		local internal: TestUtils.InternalController = TestUtils.internal(actions)
		local failureValue = { reason = "N8PrivateActionObserverFailure" }
		local observed: { any } = {}

		local disconnect: () -> () = internal:_observeMutations(function(mutations: { TestUtils.Mutation })
			table.insert(observed, {
				mutations = mutations,
				active = internal:_getActiveReplicationState(),
				mana = resources:GetCurrent("Mana"),
				incoming = tags:HasTag("Incoming"),
				notifications = #order,
			})

			error(failureValue, 0)
		end)

		table.insert(disconnects, disconnect)
		local surviving: { { TestUtils.Mutation } } = {}

		table.insert(
			disconnects,
			internal:_observeMutations(function(mutations: { TestUtils.Mutation })
				table.insert(surviving, mutations)
			end)
		)

		local success: boolean, failure: any = pcall(function()
			actions:RequestAction("Incoming")
		end)

		expect(success).toBe(false)
		expect(failure).toBe(failureValue)
		expectCommittedStart(1)

		expect(observed).toEqual({
			{
				mutations = { { kind = "Started", actionId = "Incoming", sequenceId = 1 } },
				active = { { actionId = "Incoming", sequenceId = 1 } },
				mana = 80,
				incoming = true,
				notifications = 0,
			},
		})

		expect(surviving).toEqual({ { { kind = "Started", actionId = "Incoming", sequenceId = 1 } } })
		canonical(1, { [1] = "Incoming" }, 80, { Incoming = { stackCount = 1 } })
		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ actionEvent("Started", "Incoming", 1) })
		disconnect()
		expect(TestUtils.accept(actions, "Later")).toBe(2)

		canonical(
			2,
			{ [1] = "Incoming", [2] = "Later" },
			70,
			{ Incoming = { stackCount = 1 }, OwnerB = { stackCount = 1 } }
		)

		expect(#observed).toBe(1)
		expect(#surviving).toBe(2)
		expect(#commits).toBe(2)
		expect(TestUtils.events(commits[2])).toEqual({ actionEvent("Started", "Later", 2) })
	end
)

it(
	"keeps End cleanup committed after rejected publication and reconciles later truth without replaying Ended",
	function()
		setup()
		expect(TestUtils.accept(actions, "Incoming")).toBe(1)
		local previous: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
		assert(previous ~= nil, "Expected admitted activation")
		order = {}
		lifecycleTruth = {}
		table.clear(commits)
		rejectCapture = true

		local success: boolean, failure: any = pcall(function()
			actions:EndAction(1)
		end)

		expect(success).toBe(false)
		expect(failure).toBe("InvalidPublicationSnapshot:KRF.Tags")
		expect(rejectedAuthority).toEqual({ { active = false, mana = 80, incoming = false } })
		expect(resources:GetCurrent("Mana")).toBe(80)
		expect(tags:HasTag("Incoming")).toBe(false)
		expect(contexts[1]:IsActive()).toBe(false)
		expect(publication:CaptureBaseline(actor)).toEqual(previous)
		expect(commits).toEqual({})
		expect(order).toEqual({ "Ended:1", "TagRemoved:Incoming", "EndHook:1" })

		expect(lifecycleTruth).toEqual({
			{
				kind = "Ended",
				sequenceId = 1,
				active = false,
				mana = 80,
				incoming = false,
				revision = previous.sequence,
			},
		})

		expect(reasons).toEqual({})
		local ended: boolean, reason: string? = actions:EndAction(1)
		expect(ended).toBe(false)
		expect(reason).toBe("ActionInstanceNotActive")
		expect(#order).toBe(3)
		rejectCapture = false
		-- Reusing the same lifetime lock must succeed, without refunding the first cost.
		expect(TestUtils.accept(actions, "Incoming")).toBe(2)
		canonical(2, { [2] = "Incoming" }, 60, { Incoming = { stackCount = 1 } })
		expect(#commits).toBe(1)
		expect(commits[1].sequence).toBe(2)
		expect(TestUtils.events(commits[1])).toEqual({ actionEvent("Started", "Incoming", 2) })
		expect(contexts[1]:IsActive()).toBe(false)
		expect(contexts[2]:IsActive()).toBe(true)
	end
)

it(
	"retains admitted Interrupt cleanup despite downstream failure and never redelivers its terminal event or reason",
	function()
		setup()
		expect(TestUtils.accept(actions, "Incoming")).toBe(1)
		order = {}
		lifecycleTruth = {}
		table.clear(commits)
		local failureValue = { reason = "N8TerminalDeliveryFailure" }
		local delivered: { number } = {}

		table.insert(
			disconnects,
			publication:ObserveCommits(function()
				error(failureValue, 0)
			end)
		)

		table.insert(
			disconnects,
			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
				table.insert(delivered, commit.sequence)
			end)
		)

		local success: boolean, failure: any = pcall(function()
			actions:InterruptAction(1, "ServerOnlyReason")
		end)

		expect(success).toBe(false)
		expect(failure).toBe(failureValue)
		expect(resources:GetCurrent("Mana")).toBe(80)
		expect(tags:HasTag("Incoming")).toBe(false)
		expect(contexts[1]:IsActive()).toBe(false)
		expect(order).toEqual({ "Interrupted:1", "TagRemoved:Incoming", "InterruptHook:1" })

		expect(lifecycleTruth).toEqual({
			{ kind = "Interrupted", sequenceId = 1, active = false, mana = 80, incoming = false, revision = 2 },
		})

		expect(reasons).toEqual({ "ServerOnlyReason", "ServerOnlyReason" })
		canonical(2, {}, 80, {})
		expect(delivered).toEqual({ 2 })
		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ actionEvent("Interrupted", "Incoming", 1) })
		disconnects[1]()
		local interrupted: boolean, reason: string? = actions:InterruptAction(1, "Duplicate")
		expect(interrupted).toBe(false)
		expect(reason).toBe("ActionInstanceNotActive")
		expect(#order).toBe(3)
		expect(TestUtils.accept(actions, "Incoming")).toBe(2)
		canonical(3, { [2] = "Incoming" }, 60, { Incoming = { stackCount = 1 } })
		expect(delivered).toEqual({ 2, 3 })
		expect(#commits).toBe(2)
		expect(TestUtils.events(commits[2])).toEqual({ actionEvent("Started", "Incoming", 2) })
		expect(reasons).toEqual({ "ServerOnlyReason", "ServerOnlyReason" })
	end
)
