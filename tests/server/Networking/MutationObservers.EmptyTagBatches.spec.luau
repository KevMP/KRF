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
local TagTypes = require(KRF.server.Tags.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
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

local function initialize(definitions: { ActionTypes.ActionDefinition }): ()
	ActionUtils.initialize(definitions, {
		{
			id = "Mana",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 100,
			max = { propertyName = "MaxMana", defaultBaseValue = 100 },
		},
	}, {
		{
			id = "Capacity",
			visibility = "ClientVisible",
			duplicateBehavior = "Refresh",
			properties = { MaxMana = { set = 50 } },
		},
	})
end

for _, operation: string in { "Start", "End", "Interrupt", "ClaimLocks", "Destroy" } do
	it(`does not deliver private Tag phases for tagless Action {operation}`, function()
		local order: { string } = {}
		local contexts: { [string]: ActionTypes.ActionExecutionContext } = {}

		local function started(context: ActionTypes.ActionExecutionContext): ()
			contexts[context.actionId] = context
			table.insert(order, "start " .. context.actionId)
		end

		local function ended(context: ActionTypes.ActionExecutionContext): ()
			table.insert(order, "end " .. context.actionId)
		end

		local function interrupted(context: ActionTypes.ActionExecutionContext): ()
			table.insert(order, "interrupt " .. context.actionId)
		end

		initialize({
			{
				id = "Worker",
				visibility = "ClientVisible",
				autoGrant = true,
				costs = { Mana = 10 },
				onStart = started,
				onEnd = ended,
				onInterrupt = interrupted,
			},
			{
				id = "Owner",
				visibility = "ClientVisible",
				autoGrant = true,
				locks = { "Hands" },
				interruptibleBy = { "Claimant" },
				onStart = started,
				onInterrupt = interrupted,
			},
			{
				id = "Claimant",
				visibility = "ClientVisible",
				autoGrant = true,
				onStart = started,
			},
		})

		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, publicResources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
			ActionUtils.registerActor()

		if operation == "ClaimLocks" then
			TestUtils.accept(actions, "Owner")
			TestUtils.accept(actions, "Claimant")
		elseif operation ~= "Start" then
			TestUtils.accept(actions, "Worker")

			if operation == "Destroy" then
				TestUtils.accept(actions, "Owner")
			end
		end

		table.clear(order)
		local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

		local properties: PropertyTypes.InternalPropertyController =
			publicProperties :: PropertyTypes.InternalPropertyController

		local resources: ResourceTypes.InternalResourceController =
			publicResources :: ResourceTypes.InternalResourceController

		local tagCalls: number = 0
		local propertyCalls: number = 0
		local resourceCommits: number = 0
		local resourceDispatches: number = 0

		local function unexpectedTagDelivery(): ()
			tagCalls += 1

			if operation == "End" or operation == "Destroy" then
				coroutine.yield()
			else
				error("UnexpectedEmptyTagDelivery", 0)
			end
		end

		table.insert(
			disconnects,
			tags:_observeMutations({
				Commit = unexpectedTagDelivery,
				Dispatch = unexpectedTagDelivery,
			})
		)

		table.insert(
			disconnects,
			properties:_observeResolvedMutations({
				Commit = function(): ()
					propertyCalls += 1
				end,
				Dispatch = function(): ()
					propertyCalls += 1
				end,
			})
		)

		table.insert(
			disconnects,
			resources:_observeMutations({
				Commit = function(): ()
					resourceCommits += 1
				end,
				Dispatch = function(): ()
					resourceDispatches += 1
				end,
			})
		)

		local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
		local before: number? = publication:GetActorSequence(actor)
		assert(before ~= nil, "Expected admitted Actor")
		local commits: { NetworkingTypes.PublicationCommit } = {}
		local lifecycleSequences: { number? } = {}

		table.insert(
			disconnects,
			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
				table.insert(commits, commit)
				table.insert(order, "Publication")
			end)
		)

		local function observeLifecycle(kind: string, change: ActionTypes.ActionLifecycleEvent): ()
			table.insert(order, kind .. " " .. change.actionId)
			table.insert(lifecycleSequences, publication:GetActorSequence(actor))
		end

		table.insert(
			connections,
			actions.OnActionStarted:Connect(function(change: ActionTypes.ActionLifecycleEvent): ()
				observeLifecycle("Started", change)
			end)
		)

		table.insert(
			connections,
			actions.OnActionEnded:Connect(function(change: ActionTypes.ActionLifecycleEvent): ()
				observeLifecycle("Ended", change)
			end)
		)

		table.insert(
			connections,
			actions.OnActionInterrupted:Connect(function(change: ActionTypes.ActionInterruptedEvent): ()
				observeLifecycle("Interrupted", change)
			end)
		)

		table.insert(
			connections,
			resources.OnResourceChanged:Connect(function(): ()
				table.insert(order, "Resource")
			end)
		)

		local success: boolean, failure: any = pcall(function(): ()
			if operation == "Start" then
				expect(actions:RequestAction("Worker")).toEqual({ accepted = true, sequenceId = 1 })
			elseif operation == "End" then
				expect(actions:EndAction(1)).toBe(true)
			elseif operation == "Interrupt" then
				expect(actions:InterruptAction(1, "TestInterrupt")).toBe(true)
			elseif operation == "ClaimLocks" then
				local claim: ActionTypes.LockClaim?, reason: string? = contexts.Claimant:ClaimLocks({ "Hands" })
				expect(reason).toBeNil()
				expect(claim).never.toBeNil()
			else
				actions:Destroy()
			end
		end)

		expect(success).toBe(true)
		expect(failure).toBeNil()
		expect(tagCalls).toBe(0)
		expect(propertyCalls).toBe(0)
		expect(resources:GetCurrent("Mana")).toBe(if operation == "ClaimLocks" then 100 else 90)
		expect(resourceCommits).toBe(if operation == "Start" then 1 else 0)
		expect(resourceDispatches).toBe(if operation == "Start" then 1 else 0)
		expect(tags:GetActiveTags()).toEqual({})
		expect(properties:GetResolvedProperty("MaxMana")).toBe(100)
		expect(#commits).toBe(1)
		expect(commits[1].sequence).toBe(before + 1)

		expect(lifecycleSequences).toEqual(
			if operation == "Destroy" then { before + 1, before + 1 } else { before + 1 }
		)

		local eventHistory: { string } = {}

		for _, event: NetworkingTypes.PublicationEvent in TestUtils.events(commits[1]) do
			table.insert(eventHistory, event.eventId .. " " .. event.payload.actionId)
		end

		if operation == "Start" then
			expect(order).toEqual({ "Publication", "Started Worker", "Resource", "start Worker" })
			expect(eventHistory).toEqual({ "Started Worker" })
			expect(TestUtils.state(actor)).toEqual({ [1] = "Worker" })
		elseif operation == "End" then
			expect(order).toEqual({ "Publication", "Ended Worker", "end Worker" })
			expect(eventHistory).toEqual({ "Ended Worker" })
			expect(TestUtils.state(actor)).toEqual({})
		elseif operation == "Interrupt" then
			expect(order).toEqual({ "Publication", "Interrupted Worker", "interrupt Worker" })
			expect(eventHistory).toEqual({ "Interrupted Worker" })
			expect(TestUtils.state(actor)).toEqual({})
		elseif operation == "ClaimLocks" then
			expect(order).toEqual({ "Publication", "Interrupted Owner", "interrupt Owner" })
			expect(eventHistory).toEqual({ "Interrupted Owner" })
			expect(TestUtils.state(actor)).toEqual({ [2] = "Claimant" })
		else
			expect(order).toEqual({
				"Publication",
				"Interrupted Worker",
				"Interrupted Owner",
				"interrupt Worker",
				"interrupt Owner",
			})

			expect(eventHistory).toEqual({ "Interrupted Worker", "Interrupted Owner" })
			expect(TestUtils.state(actor)).toEqual({})
		end
	end)
end

it("leaves non-empty Tag notification ownership with its batch across nested and later empty batches", function()
	initialize({})

	local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
		ActionUtils.registerActor()

	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
	local tagCommits: { { TagTypes.TagMutationEvent } } = {}
	local tagDispatches: number = 0
	local order: { string } = {}
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	local before: number? = TestUtils.publication():GetActorSequence(actor)
	assert(before ~= nil, "Expected admitted Actor")

	table.insert(
		disconnects,
		tags:_observeMutations({
			Commit = function(events: { TagTypes.TagMutationEvent }): ()
				table.insert(tagCommits, table.clone(events))
			end,
			Dispatch = function(): ()
				tagDispatches += 1
			end,
		})
	)

	table.insert(
		connections,
		tags.OnTagAdded:Connect(function(): ()
			table.insert(order, "Added")
		end)
	)

	table.insert(
		connections,
		tags.OnTagChanged:Connect(function(): ()
			table.insert(order, "Changed")
		end)
	)

	table.insert(
		connections,
		properties.OnResolvedPropertyChanged:Connect(function(): ()
			table.insert(order, "Property")
		end)
	)

	table.insert(
		connections,
		resources.OnResourceChanged:Connect(function(): ()
			table.insert(order, "Resource")
		end)
	)

	tags:_beginMutationBatch()
	expect(tags:AddTag("Capacity")).toBe(true)
	tags:_beginMutationBatch()
	local nested: { TagTypes.TagMutationEvent } = tags:_finishMutationBatch()
	expect(nested).toEqual({})
	tags:_dispatchMutationEvents(nested)
	expect(tagCommits).toEqual({})
	expect(tagDispatches).toBe(0)
	expect(order).toEqual({})
	expect(#commits).toBe(0)
	expect(tags:HasTag("Capacity")).toBe(true)
	expect(properties:GetResolvedProperty("MaxMana")).toBe(100)
	expect(resources:GetMax("Mana")).toBe(100)

	local pending: { TagTypes.TagMutationEvent } = tags:_finishMutationBatch()
	expect(pending).toEqual({ { kind = "Added", tagId = "Capacity" } })
	expect(tagCommits).toEqual({ pending })
	expect(order).toEqual({})
	expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
	expect(resources:GetMax("Mana")).toBe(50)
	expect(resources:GetCurrent("Mana")).toBe(50)
	expect(#commits).toBe(2)
	local admitted: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(admitted ~= nil, "Expected committed Tag and Resource authority")
	expect(admitted.sequence).toBe(before + 2)
	expect(admitted.domains["KRF.Tags"].value.Capacity).never.toBeNil()
	expect(admitted.domains["KRF.Resources"].value.Mana.max).toBe(50)

	tags:_beginMutationBatch()
	local empty: { TagTypes.TagMutationEvent } = tags:_finishMutationBatch()
	tags:_dispatchMutationEvents(empty)
	expect(empty).toEqual({})
	expect(tagCommits).toEqual({ pending })
	expect(tagDispatches).toBe(0)
	expect(order).toEqual({})
	expect(#commits).toBe(2)

	tags:_dispatchMutationEvents(pending)
	expect(order).toEqual({ "Added", "Changed", "Property", "Resource" })
	expect(tagDispatches).toBe(1)
	expect(tagCommits).toEqual({ pending })
	expect(#commits).toBe(2)
	local history: { string } = {}

	for _, commit: NetworkingTypes.PublicationCommit in commits do
		for _, event: NetworkingTypes.PublicationEvent in commit.events do
			table.insert(history, event.domainId .. ":" .. event.eventId)
		end
	end

	expect(history).toEqual({ "KRF.Tags:Added" })
end)

it("skips empty cleanup delivery when an external refresh invalidated the Action's owned Tag receipt", function()
	local order: { string } = {}

	initialize({
		{
			id = "Owner",
			visibility = "ClientVisible",
			autoGrant = true,
			activeTags = { "Capacity" },
			onEnd = function(): ()
				table.insert(order, "end")
			end,
		},
	})

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
		ActionUtils.registerActor()

	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
	TestUtils.accept(actions, "Owner")
	expect(tags:AddTag("Capacity", { duration = 5 })).toBe(true)
	local retained: { TagTypes.TagInstanceSnapshot } = tags:GetTagInstances("Capacity")
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	local calls: number = 0

	local function unexpectedDelivery(): ()
		calls += 1
		error("UnexpectedObsoleteReceiptDelivery", 0)
	end

	table.insert(disconnects, tags:_observeMutations({ Commit = unexpectedDelivery, Dispatch = unexpectedDelivery }))

	table.insert(
		connections,
		actions.OnActionEnded:Connect(function(): ()
			table.insert(order, "Ended")
		end)
	)

	local success: boolean, failure: any = pcall(function(): ()
		expect(actions:EndAction(1)).toBe(true)
	end)

	expect(success).toBe(true)
	expect(failure).toBeNil()
	expect(calls).toBe(0)
	expect(order).toEqual({ "Ended", "end" })
	expect(tags:GetTagInstances("Capacity")).toEqual(retained)
	expect(resources:GetMax("Mana")).toBe(50)
	expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
	expect(TestUtils.state(actor)).toEqual({})
	expect(#commits).toBe(1)

	expect(TestUtils.events(commits[1])).toEqual({
		{ domainId = "KRF.Actions", eventId = "Ended", payload = { actionId = "Owner", sequenceId = 1 } },
	})
end)

it("retains independent Resource failure delivery and recovery when a paid Action has no Tag mutations", function()
	local order: { string } = {}

	initialize({
		{
			id = "Worker",
			visibility = "ClientVisible",
			autoGrant = true,
			costs = { Mana = 10 },
			onStart = function(): ()
				table.insert(order, "start")
			end,
		},
	})

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, publicResources: ResourceTypes.ResourceController, _, publicTags: TagTypes.TagController =
		ActionUtils.registerActor()

	local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

	local resources: ResourceTypes.InternalResourceController =
		publicResources :: ResourceTypes.InternalResourceController

	local original = { reason = "ResourceCommitFailure" }
	local tagCalls: number = 0
	local goodCommits: number = 0
	local goodDispatches: number = 0

	local function unexpectedTagDelivery(): ()
		tagCalls += 1
		error("UnexpectedEmptyTagDelivery", 0)
	end

	table.insert(
		disconnects,
		tags:_observeMutations({
			Commit = unexpectedTagDelivery,
			Dispatch = unexpectedTagDelivery,
		})
	)

	local disconnectFailure: () -> () = resources:_observeMutations({
		Commit = function(): ()
			error(original, 0)
		end,
		Dispatch = function(): ()
			error("LaterResourceDispatchFailure", 0)
		end,
	})

	table.insert(disconnects, disconnectFailure)

	table.insert(
		disconnects,
		resources:_observeMutations({
			Commit = function(): ()
				goodCommits += 1
			end,
			Dispatch = function(): ()
				goodDispatches += 1
			end,
		})
	)

	local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
	local before: number = publication:GetActorSequence(actor)
	local commits: { NetworkingTypes.PublicationCommit } = {}
	local changes: { ResourceTypes.ResourceChange } = {}

	table.insert(
		disconnects,
		publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
			table.insert(commits, commit)
			table.insert(order, "Publication")
		end)
	)

	table.insert(
		connections,
		actions.OnActionStarted:Connect(function(): ()
			table.insert(order, "Started")
		end)
	)

	table.insert(
		connections,
		resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange): ()
			table.insert(changes, change)
			table.insert(order, "Resource")
		end)
	)

	local success: boolean, failure: any = pcall(function(): ()
		actions:RequestAction("Worker")
	end)

	expect(success).toBe(false)
	expect(failure).toBe(original)
	expect(order).toEqual({ "Publication", "Started", "Resource", "start" })
	expect(tagCalls).toBe(0)
	expect(goodCommits).toBe(1)
	expect(goodDispatches).toBe(1)
	expect(resources:GetCurrent("Mana")).toBe(90)
	expect(TestUtils.state(actor)).toEqual({ [1] = "Worker" })
	expect(#changes).toBe(1)
	expect(changes[1].currentOldValue).toBe(100)
	expect(changes[1].currentNewValue).toBe(90)
	expect(#commits).toBe(1)
	local admitted: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
	assert(admitted ~= nil, "Expected coherent paid Action publication after Resource failure")
	expect(admitted.sequence).toBe(before + 1)
	expect(admitted.domains["KRF.Resources"].value.Mana.anchorValue).toBe(90)

	disconnectFailure()
	expect(actions:EndAction(1)).toBe(true)
	expect(actions:RequestAction("Worker")).toEqual({ accepted = true, sequenceId = 2 })
	expect(tagCalls).toBe(0)
	expect(goodCommits).toBe(2)
	expect(goodDispatches).toBe(2)
	expect(resources:GetCurrent("Mana")).toBe(80)
	expect(TestUtils.state(actor)).toEqual({ [2] = "Worker" })
	expect(#changes).toBe(2)
	expect(changes[2].currentOldValue).toBe(90)
	expect(changes[2].currentNewValue).toBe(80)
	expect(#commits).toBe(3)
	expect(publication:GetActorSequence(actor)).toBe(before + 3)
	local history: { string } = {}

	for _, commit: NetworkingTypes.PublicationCommit in commits do
		for _, event: NetworkingTypes.PublicationEvent in TestUtils.events(commit) do
			table.insert(history, event.eventId .. ":" .. event.payload.sequenceId)
		end
	end

	expect(history).toEqual({ "Started:1", "Ended:1", "Started:2" })
end)
