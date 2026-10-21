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

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
	connections = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	ActionUtils.cleanup()
end)

for _, operation: string in { "Start", "End", "Interrupt", "ClaimLocks", "Destroy" } do
	it(
		"finishes "
			.. operation
			.. " publication and lifecycle delivery before rethrowing a private Tag finalization failure",
		function()
			local order: { string } = {}
			local contexts: { [number]: ActionTypes.ActionExecutionContext } = {}
			local definitions: { ActionTypes.ActionDefinition } = {}

			for _, id: string in { "A", "B", "Incoming", "Claimant", "Later", "Probe" } do
				local definition: ActionTypes.ActionDefinition =
					TestUtils.action(id, if id == "Probe" then "ServerOnly" else "ClientVisible")

				definition.onStart = function(context: ActionTypes.ActionExecutionContext)
					contexts[context.sequenceId] = context
					table.insert(order, "StartHook:" .. id .. ":" .. context.sequenceId)
				end

				definition.onEnd = function(context: ActionTypes.ActionExecutionContext)
					table.insert(order, "EndHook:" .. id .. ":" .. context.sequenceId)
				end

				definition.onInterrupt = function(context: ActionTypes.ActionExecutionContext, reason: string)
					table.insert(order, "InterruptHook:" .. id .. ":" .. context.sequenceId .. ":" .. reason)
				end

				if id == "A" or id == "B" then
					definition.locks = { if id == "A" then "Hands" else "Feet" }
					definition.activeTags = { if id == "A" then "OwnerA" else "OwnerB" }
					definition.interruptibleBy = { "Incoming", "Claimant" }
				elseif id == "Incoming" then
					definition.locks = { "Hands", "Feet" }
					definition.activeTags = { "Incoming" }
					definition.costs = { Mana = 20 }
				elseif id == "Later" then
					definition.costs = { Mana = 10 }
					definition.activeTags = { "Applied" }
				elseif id == "Probe" then
					definition.locks = { "Hands" }
				end

				table.insert(definitions, definition)
			end

			TestUtils.initialize(definitions)

			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController =
				ActionUtils.registerActor()

			local tags: TagTypes.InternalTagController =
				actor:GetController("TagController") :: TagTypes.InternalTagController

			local internal: ActionTypes.InternalActionController = TestUtils.internal(actions)
			local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()

			if operation == "End" or operation == "Interrupt" then
				TestUtils.accept(actions, "Incoming")
			else
				TestUtils.accept(actions, "A")
				TestUtils.accept(actions, "B")

				if operation == "ClaimLocks" then
					TestUtils.accept(actions, "Claimant")
				end
			end

			table.clear(order)
			local previousSequence: number = publication:GetActorSequence(actor)
			local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
			local publicTruth: { NetworkingTypes.PublicationBaseline } = {}

			local function recordLifecycle(kind: string, event: ActionTypes.ActionLifecycleEvent): ()
				local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(baseline ~= nil, "Expected retained Actor publication")
				table.insert(publicTruth, baseline)
				table.insert(order, kind .. ":" .. event.actionId .. ":" .. event.sequenceId)
			end

			table.insert(
				connections,
				actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
					recordLifecycle("Started", event)
				end)
			)

			table.insert(
				connections,
				actions.OnActionEnded:Connect(function(event: ActionTypes.ActionLifecycleEvent)
					recordLifecycle("Ended", event)
				end)
			)

			table.insert(
				connections,
				actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
					recordLifecycle("Interrupted", event)
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

			local failureValue = { reason = "PrivateTagFinalizationFailure" }
			local tagBatches: { { TagTypes.TagMutationEvent } } = {}
			local authorityAtFailure: { { ActionTypes.ActionReplicationIdentity } } = {}
			local healthyTagCommits: number = 0
			local tagDispatches: number = 0

			table.insert(
				disconnects,
				tags:_observeMutations({
					Commit = function(events: { TagTypes.TagMutationEvent })
						table.insert(tagBatches, events)
						table.insert(authorityAtFailure, internal:_getActiveReplicationState())
						expect(order).toEqual({})
						error(failureValue, 0)
					end,
					Dispatch = function()
						tagDispatches += 1
					end,
				})
			)

			table.insert(
				disconnects,
				tags:_observeMutations({
					Commit = function()
						healthyTagCommits += 1
					end,
					Dispatch = function() end,
				})
			)

			local actionBatches: { { ActionTypes.ActionReplicationMutation } } = {}

			table.insert(
				disconnects,
				internal:_observeMutations(function(batch: { ActionTypes.ActionReplicationMutation })
					table.insert(actionBatches, batch)
				end)
			)

			local succeeded: boolean, failure: any = pcall(function()
				if operation == "Start" then
					actions:RequestAction("Incoming")
				elseif operation == "End" then
					actions:EndAction(1)
				elseif operation == "Interrupt" then
					actions:InterruptAction(1, "ServerReason")
				elseif operation == "ClaimLocks" then
					contexts[3]:ClaimLocks({ "Feet", "Hands" })
				else
					actions:Destroy()
				end
			end)

			expect(succeeded).toBe(false)
			expect(failure).toBe(failureValue)

			local active: { ActionTypes.ActionReplicationIdentity } = if operation == "Start"
				then { { actionId = "Incoming", sequenceId = 3 } }
				elseif operation == "ClaimLocks" then { { actionId = "Claimant", sequenceId = 3 } }
				else {}

			expect(authorityAtFailure).toEqual({ active })
			expect(internal:_getActiveReplicationState()).toEqual(active)

			local mana: number = if operation == "Start"
					or operation == "End"
					or operation == "Interrupt"
				then 80
				else 100

			expect(resources:GetCurrent("Mana")).toBe(mana)
			expect(tags:HasTag("OwnerA")).toBe(false)
			expect(tags:HasTag("OwnerB")).toBe(false)
			expect(tags:HasTag("Incoming")).toBe(operation == "Start")
			expect(healthyTagCommits).toBe(1)
			expect(tagDispatches).toBe(if operation == "End" or operation == "Interrupt" then 1 else 3)
			local expectedMutations: { ActionTypes.ActionReplicationMutation }

			if operation == "End" or operation == "Interrupt" then
				local kind: ActionTypes.ActionReplicationMutationKind = if operation == "End"
					then "Ended"
					else "Interrupted"

				local terminal: ActionTypes.ActionReplicationMutation =
					{ kind = kind, actionId = "Incoming", sequenceId = 1 }

				expectedMutations = { terminal }
				expect(tagBatches).toEqual({ { { kind = "Removed", tagId = "Incoming" } } })

				expect(order).toEqual({
					kind .. ":Incoming:1",
					"TagRemoved:Incoming",
					if operation == "End" then "EndHook:Incoming:1" else "InterruptHook:Incoming:1:ServerReason",
				})
			else
				local first: ActionTypes.ActionReplicationMutation =
					{ kind = "Interrupted", actionId = "A", sequenceId = 1 }

				local second: ActionTypes.ActionReplicationMutation =
					{ kind = "Interrupted", actionId = "B", sequenceId = 2 }

				expectedMutations = { first, second }

				local reason: string = if operation == "Destroy"
					then "ActionControllerDestroyed"
					else "ActionLockPreempted"

				local expectedOrder: { string } = { "Interrupted:A:1", "Interrupted:B:2" }

				local expectedTags: { TagTypes.TagMutationEvent } =
					{ { kind = "Removed", tagId = "OwnerA" }, { kind = "Removed", tagId = "OwnerB" } }

				if operation == "Start" then
					local started: ActionTypes.ActionReplicationMutation =
						{ kind = "Started", actionId = "Incoming", sequenceId = 3 }

					table.insert(expectedMutations, started)
					table.insert(expectedOrder, "Started:Incoming:3")
					local added: TagTypes.TagMutationEvent = { kind = "Added", tagId = "Incoming" }
					table.insert(expectedTags, added)
				end

				table.insert(expectedOrder, "TagRemoved:OwnerA")
				table.insert(expectedOrder, "TagRemoved:OwnerB")

				if operation == "Start" then
					table.insert(expectedOrder, "TagAdded:Incoming")
					table.insert(expectedOrder, "Resource:100->80")
				end

				table.insert(expectedOrder, "InterruptHook:A:1:" .. reason)
				table.insert(expectedOrder, "InterruptHook:B:2:" .. reason)

				if operation == "Start" then
					table.insert(expectedOrder, "StartHook:Incoming:3")
				end

				expect(tagBatches).toEqual({ expectedTags })
				expect(order).toEqual(expectedOrder)
			end

			expect(actionBatches).toEqual({ expectedMutations })
			expect(contexts[1]:IsActive()).toBe(false)

			if contexts[2] ~= nil then
				expect(contexts[2]:IsActive()).toBe(false)
			end

			if #active > 0 then
				expect(contexts[3]:IsActive()).toBe(true)
			end

			local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected committed Actor publication")
			expect(baseline.sequence).toBe(previousSequence + 1)

			expect(baseline.domains["KRF.Actions"].value).toEqual(
				if operation == "Start"
					then { [3] = "Incoming" }
					elseif operation == "ClaimLocks" then { [3] = "Claimant" }
					else {}
			)

			expect(baseline.domains["KRF.Tags"].value).toEqual(
				if operation == "Start" then { Incoming = { stackCount = 1 } } else {}
			)

			expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(mana)
			expect(#commits).toBe(1)
			local expectedEvents: { NetworkingTypes.PublicationEvent } = {}

			for _, mutation: ActionTypes.ActionReplicationMutation in expectedMutations do
				table.insert(expectedEvents, {
					domainId = "KRF.Actions",
					eventId = mutation.kind,
					payload = { actionId = mutation.actionId, sequenceId = mutation.sequenceId },
				})
			end

			expect(TestUtils.events(commits[1])).toEqual(expectedEvents)

			for _, observed: NetworkingTypes.PublicationBaseline in publicTruth do
				expect(observed).toEqual(baseline)
			end

			disconnects[1]()
			table.clear(commits)

			if operation == "Destroy" then
				actions:Destroy()

				expect(actions:RequestAction("Later")).toEqual({
					accepted = false,
					reason = "ActionControllerDestroyed",
				})

				expect(resources:SetCurrent("Mana", 90)).toBe(true)
				expect(#commits).toBe(1)
				expect(commits[1].sequence).toBe(previousSequence + 2)
				expect(TestUtils.events(commits[1])).toEqual({})
				local recovered: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(recovered ~= nil, "Expected publication after Action destruction")
				expect(recovered.domains["KRF.Actions"].value).toEqual({})
				expect(recovered.domains["KRF.Resources"].value.Mana.anchorValue).toBe(90)
			else
				local sequenceId: number = TestUtils.accept(actions, "Later")
				expect(resources:GetCurrent("Mana")).toBe(mana - 10)
				expect(#commits).toBe(1)
				expect(commits[1].sequence).toBe(previousSequence + 2)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Started",
						payload = { actionId = "Later", sequenceId = sequenceId },
					},
				})

				local recovered: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(recovered ~= nil, "Expected later Action publication")
				expect(recovered.domains["KRF.Actions"].value[sequenceId]).toBe("Later")
				expect(recovered.domains["KRF.Resources"].value.Mana.anchorValue).toBe(mana - 10)

				if operation == "Start" or operation == "ClaimLocks" then
					expect(actions:RequestAction("Probe")).toEqual({ accepted = false, reason = "ActionLockConflict" })
					expect(actions:EndAction(3)).toBe(true)
				end

				TestUtils.accept(actions, "Probe")
			end
		end
	)
end
