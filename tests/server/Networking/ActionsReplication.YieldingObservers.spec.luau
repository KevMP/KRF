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
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local disconnects: { () -> () } = {}
local connections: { SignalTypes.Connection } = {}
local threads: { thread } = {}

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
	connections = {}
	threads = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	for _, suspended: thread in threads do
		pcall(task.cancel, suspended)
		pcall(coroutine.close, suspended)
	end

	ActionUtils.cleanup()
end)

for _, domain: string in { "Tag", "Resource" } do
	for _, phase: string in { "Commit", "Dispatch" } do
		it(
			"cancels a yielding private " .. domain .. " " .. phase .. " without suspending committed Action delivery",
			function()
				local order: { string } = {}
				local contexts: { [number]: ActionTypes.ActionExecutionContext } = {}

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

				local probe: ActionTypes.ActionDefinition = TestUtils.action("Probe", "ServerOnly")
				probe.locks = { "Hands" }
				TestUtils.initialize({ incoming, probe })

				local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController =
					ActionUtils.registerActor()

				local tags: TagTypes.InternalTagController =
					actor:GetController("TagController") :: TagTypes.InternalTagController

				local internalResources: ResourceTypes.InternalResourceController =
					resources :: ResourceTypes.InternalResourceController

				local internalActions: ActionTypes.InternalActionController = TestUtils.internal(actions)
				local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
				local previousSequence: number = publication:GetActorSequence(actor)
				local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
				local publicTruth: { NetworkingTypes.PublicationBaseline } = {}

				local function lifecycle(kind: string, event: ActionTypes.ActionLifecycleEvent): ()
					local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
					assert(baseline ~= nil, "Expected retained Actor publication")
					table.insert(publicTruth, baseline)
					table.insert(order, kind .. ":" .. event.sequenceId)
				end

				table.insert(
					connections,
					actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
						lifecycle("Started", event)
					end)
				)

				table.insert(
					connections,
					actions.OnActionEnded:Connect(function(event: ActionTypes.ActionLifecycleEvent)
						lifecycle("Ended", event)
					end)
				)

				table.insert(
					connections,
					tags.OnTagAdded:Connect(function(_actor: ActorTypes.Actor, id: string)
						table.insert(order, "TagAdded:" .. id)
					end)
				)

				table.insert(
					connections,
					tags.OnTagRemoved:Connect(function(_actor: ActorTypes.Actor, id: string)
						table.insert(order, "TagRemoved:" .. id)
					end)
				)

				table.insert(
					connections,
					resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
						table.insert(order, `Resource:{change.currentOldValue}->{change.currentNewValue}`)
					end)
				)

				local observerThread: thread? = nil
				local continued: boolean = false
				local orderAtYield: { string } = {}
				local healthyCommits: number = 0
				local healthyDispatches: number = 0

				local function suspend(): ()
					observerThread = coroutine.running()
					table.insert(threads, coroutine.running())
					orderAtYield = table.clone(order)
					coroutine.yield()
					continued = true
				end

				local function commit(_mutations: any): ()
					if phase == "Commit" then
						suspend()
					end
				end

				local function dispatch(): ()
					if phase == "Dispatch" then
						suspend()
					end
				end

				local healthy = {
					Commit = function()
						healthyCommits += 1
					end,
					Dispatch = function()
						healthyDispatches += 1
					end,
				}

				if domain == "Tag" then
					local observer: TagTypes.TagMutationObserver = { Commit = commit, Dispatch = dispatch }
					table.insert(disconnects, tags:_observeMutations(observer))
					table.insert(disconnects, tags:_observeMutations(healthy))
				else
					local observer: ResourceTypes.ResourceMutationObserver = { Commit = commit, Dispatch = dispatch }
					table.insert(disconnects, internalResources:_observeMutations(observer))
					table.insert(disconnects, internalResources:_observeMutations(healthy))
				end

				local mutations: { { ActionTypes.ActionReplicationMutation } } = {}

				table.insert(
					disconnects,
					internalActions:_observeMutations(function(batch: { ActionTypes.ActionReplicationMutation })
						table.insert(mutations, batch)
					end)
				)

				local succeeded: boolean? = nil
				local failure: any = nil

				-- Drive the transaction explicitly so the regression fails promptly even
				-- when a private Dispatch suspends outside N3's coroutine guard.
				local transaction: thread = coroutine.create(function()
					succeeded, failure = pcall(function()
						actions:RequestAction("Incoming")
					end)
				end)

				table.insert(threads, transaction)
				local resumedTransaction: boolean = coroutine.resume(transaction)
				expect(resumedTransaction).toBe(true)
				expect(coroutine.status(transaction)).toBe("dead")
				expect(succeeded).toBe(false)
				expect(failure).toBe(domain .. "MutationObserverYielded")
				assert(observerThread ~= nil, "Expected private observer delivery")
				expect(coroutine.status(observerThread)).toBe("dead")
				local resumedObserver: boolean = coroutine.resume(observerThread)
				expect(resumedObserver).toBe(false)
				expect(continued).toBe(false)
				expect(healthyCommits).toBe(1)

				if domain == "Resource" or phase == "Commit" then
					expect(healthyDispatches).toBe(1)
				end

				if phase == "Commit" then
					expect(orderAtYield).toEqual({})
				elseif domain == "Resource" then
					expect(orderAtYield).toEqual({ "Started:1", "TagAdded:Incoming", "Resource:100->80" })
				else
					-- The Property observer can drain Resources before this Tag observer;
					-- private Tag observer iteration does not define a relative order.
					expect({
						{ "Started:1", "TagAdded:Incoming" },
						{ "Started:1", "TagAdded:Incoming", "Resource:100->80" },
					}).toContainEqual(orderAtYield)
				end

				expect(order).toEqual({ "Started:1", "TagAdded:Incoming", "Resource:100->80", "StartHook:1" })
				expect(contexts[1]:IsActive()).toBe(true)
				expect(resources:GetCurrent("Mana")).toBe(80)
				expect(tags:HasTag("Incoming")).toBe(true)

				expect(internalActions:_getActiveReplicationState()).toEqual({
					{ actionId = "Incoming", sequenceId = 1 },
				})

				expect(actions:RequestAction("Probe")).toEqual({ accepted = false, reason = "ActionLockConflict" })
				expect(mutations).toEqual({ { { kind = "Started", actionId = "Incoming", sequenceId = 1 } } })
				local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(baseline ~= nil, "Expected admitted Action publication")
				expect(baseline.sequence).toBe(previousSequence + 1)
				expect(baseline.domains["KRF.Actions"].value).toEqual({ [1] = "Incoming" })
				expect(baseline.domains["KRF.Tags"].value).toEqual({ Incoming = { stackCount = 1 } })
				expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(80)
				expect(publicTruth).toEqual({ baseline })
				expect(#commits).toBe(1)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Started",
						payload = { actionId = "Incoming", sequenceId = 1 },
					},
				})

				disconnects[1]()
				table.clear(order)
				table.clear(commits)
				expect(actions:EndAction(1)).toBe(true)
				expect(contexts[1]:IsActive()).toBe(false)
				expect(resources:GetCurrent("Mana")).toBe(80)
				expect(tags:HasTag("Incoming")).toBe(false)
				expect(order).toEqual({ "Ended:1", "TagRemoved:Incoming", "EndHook:1" })
				expect(#commits).toBe(1)
				expect(commits[1].sequence).toBe(previousSequence + 2)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Ended",
						payload = { actionId = "Incoming", sequenceId = 1 },
					},
				})

				expect(TestUtils.state(actor)).toEqual({})
				table.clear(order)
				table.clear(commits)
				expect(TestUtils.accept(actions, "Incoming")).toBe(2)
				expect(resources:GetCurrent("Mana")).toBe(60)
				expect(contexts[2]:IsActive()).toBe(true)
				expect(order).toEqual({ "Started:2", "TagAdded:Incoming", "Resource:80->60", "StartHook:2" })
				expect(#commits).toBe(1)
				expect(commits[1].sequence).toBe(previousSequence + 3)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Started",
						payload = { actionId = "Incoming", sequenceId = 2 },
					},
				})

				expect(TestUtils.state(actor)).toEqual({ [2] = "Incoming" })
				expect(continued).toBe(false)
			end
		)
	end
end
