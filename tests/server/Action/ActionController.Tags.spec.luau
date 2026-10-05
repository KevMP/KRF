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
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local TagControllerModule = require(KRF.server.Tags.TagController)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local ActionControllerUpdates = require(KRF.server.Action.utils.ActionControllerUpdates)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController
type TagDefinition = TagTypes.TagDefinition

local actors: { Actor } = {}
local models: { Model } = {}
local now: number = 100

beforeEach(function()
	Server._ResetForTests()
	TagControllerModule._setAutomaticSteppingEnabledForTests(false)
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(false)
	now = 100
	ActionControllerUpdates._setClockForTests(function(): number
		return now
	end)
	actors = {}
	models = {}
end)

afterEach(function()
	for _, actor: Actor in actors do
		if ActorRegistry.GetActorById(actor:GetId()) ~= nil then
			ActorRuntime.UnregisterActor(actor, "TestCleanup")
		end
	end
	for _, model: Model in models do
		model:Destroy()
	end
	TagControllerModule._setAutomaticSteppingEnabledForTests(true)
	ActionControllerUpdates._setClockForTests(nil)
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(true)
	Server._ResetForTests()
end)

local function initialize(definitions: { ActionDefinition }, tags: { TagDefinition }): ()
	local factories: { ActionTypes.ActionFactory } = {}
	for _, definition: ActionDefinition in definitions do
		local source: ActionDefinition = definition
		table.insert(factories, function(): ActionDefinition
			return table.clone(source)
		end)
	end
	local started: boolean, failure = Server.Init({ actions = factories, tags = tags })
	expect(started).toBe(true)
	expect(failure).toBeNil()
end

local function registerActor(): (Actor, ActionController, TagController)
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	local registered: Actor = actor :: Actor
	table.insert(actors, registered)
	local actions: ActionController = registered:GetController("ActionController") :: ActionController
	local tags: TagController = registered:GetController("TagController") :: TagController
	expect(actions).never.toBeNil()
	expect(tags).never.toBeNil()
	return registered, actions, tags
end

local function tag(id: string, duplicateBehavior: "Stack" | "Refresh" | "Ignore"): TagDefinition
	return { id = id, duplicateBehavior = duplicateBehavior, visibility = "ServerOnly" }
end

it("checks every required and blocked Tag before onCanStart and consumes no id on rejection", function()
	local decisionCalls: number = 0
	initialize({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			requiredTags = { "Tag.Grounded", "Tag.Ready" },
			blockedTags = { "Tag.Stunned", "Tag.Rooted" },
			onCanStart = function(): (boolean, string?)
				decisionCalls += 1
				return true, nil
			end,
		},
	}, {
		tag("Tag.Grounded", "Ignore"),
		tag("Tag.Ready", "Ignore"),
		tag("Tag.Stunned", "Ignore"),
		tag("Tag.Rooted", "Ignore"),
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local missing: any = actions:RequestAction("Action.Dodge")
	expect(missing.accepted).toBe(false)
	expect(missing.reason).toBe("ActionRequiredTagMissing:Tag.Grounded")
	expect(missing.sequenceId).toBeNil()
	expect(decisionCalls).toBe(0)
	expect((tags:AddTag("Tag.Grounded"))).toBe(true)
	expect((actions:RequestAction("Action.Dodge") :: any).reason).toBe("ActionRequiredTagMissing:Tag.Ready")
	expect((tags:AddTag("Tag.Ready"))).toBe(true)
	expect((tags:AddTag("Tag.Rooted"))).toBe(true)
	expect((actions:RequestAction("Action.Dodge") :: any).reason).toBe("ActionBlockedTagPresent:Tag.Rooted")
	expect((tags:RemoveTag("Tag.Rooted"))).toBe(true)
	expect((tags:AddTag("Tag.Stunned"))).toBe(true)
	expect((actions:RequestAction("Action.Dodge") :: any).reason).toBe("ActionBlockedTagPresent:Tag.Stunned")
	expect((tags:RemoveTag("Tag.Stunned"))).toBe(true)
	expect(actions:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 1 })
	expect(decisionCalls).toBe(1)
end)

it("revalidates Tag requirements after onCanStart mutates authoritative state", function()
	local tags: TagController? = nil
	initialize({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			requiredTags = { "Tag.Grounded" },
			blockedTags = { "Tag.Stunned" },
			onCanStart = function(): (boolean, string?)
				(tags :: TagController):RemoveTag("Tag.Grounded")
				return true, nil
			end,
		},
	}, { tag("Tag.Grounded", "Ignore"), tag("Tag.Stunned", "Ignore") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	expect((registeredTags:AddTag("Tag.Grounded"))).toBe(true)
	local rejected: any = actions:RequestAction("Action.Dodge")
	expect(rejected.accepted).toBe(false)
	expect(rejected.reason).toBe("ActionRequiredTagMissing:Tag.Grounded")
	expect(rejected.sequenceId).toBeNil()
	expect(registeredTags:HasTag("Tag.Grounded")).toBe(false)
end)

it("keeps a running Action active when required or blocked Tags change later", function()
	local context: ActionTypes.ActionExecutionContext? = nil
	initialize({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			requiredTags = { "Tag.Grounded" },
			blockedTags = { "Tag.Stunned" },
			onStart = function(startedContext: ActionTypes.ActionExecutionContext)
				context = startedContext
			end,
		},
	}, { tag("Tag.Grounded", "Ignore"), tag("Tag.Stunned", "Ignore") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect((tags:AddTag("Tag.Grounded"))).toBe(true)
	local started: any = actions:RequestAction("Action.Dodge")
	expect(started.accepted).toBe(true)
	expect((tags:RemoveTag("Tag.Grounded"))).toBe(true)
	expect((tags:AddTag("Tag.Stunned"))).toBe(true)
	expect((context :: ActionTypes.ActionExecutionContext):IsActive()).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
end)

it("commits active and applied Tags before start callbacks and cleans only active Tags before end callbacks", function()
	local observations: { string } = {}
	local tags: TagController? = nil
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { { id = "Tag.Bleeding", duration = 6 } },
			onStart = function()
				if
					(tags :: TagController):HasTag("Tag.Blocking")
					and (tags :: TagController):HasTag("Tag.Bleeding")
				then
					table.insert(observations, "started with tags")
				end
			end,
			onEnd = function()
				if
					not (tags :: TagController):HasTag("Tag.Blocking")
					and (tags :: TagController):HasTag("Tag.Bleeding")
				then
					table.insert(observations, "ended with applied tag")
				end
			end,
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect(observations).toEqual({ "started with tags" })
	expect(registeredTags:GetTagInstances("Tag.Bleeding")[1].duration).toBe(6)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(observations).toEqual({ "started with tags", "ended with applied tag" })
end)

it("removes only the terminating Action's active stack contribution", function()
	initialize(
		{ { id = "Action.Block", visibility = "ServerOnly", autoGrant = true, activeTags = { "Tag.Blocking" } } :: any },
		{ tag("Tag.Blocking", "Stack") }
	)
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect((tags:AddTag("Tag.Blocking"))).toBe(true)
	local first: any = actions:RequestAction("Action.Block")
	local second: any = actions:RequestAction("Action.Block")
	expect(first.accepted).toBe(true)
	expect(second.accepted).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(3)
	expect((actions:EndAction(first.sequenceId))).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(2)
	expect((actions:InterruptAction(second.sequenceId, "Test"))).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(1)
end)

it("does not preempt an Action while its active Tag blocks the incoming request", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Action.Dodge" },
			activeTags = { "Tag.Blocking" },
		} :: any,
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			blockedTags = { "Tag.Blocking" },
		},
	}, { tag("Tag.Blocking", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local block: any = actions:RequestAction("Action.Block")
	expect(block.accepted).toBe(true)
	local dodge: any = actions:RequestAction("Action.Dodge")
	expect(dodge.accepted).toBe(false)
	expect(dodge.sequenceId).toBeNil()
	expect(tags:HasTag("Tag.Blocking")).toBe(true)
	expect((actions:EndAction(block.sequenceId))).toBe(true)
	expect(actions:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 2 })
end)

it("keeps applied Tags after interruption and controller destruction", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			appliedTags = { { id = "Tag.Bleeding", duration = 6 } },
		} :: any,
	}, { tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local first: any = actions:RequestAction("Action.Attack")
	expect(first.accepted).toBe(true)
	expect((actions:InterruptAction(first.sequenceId, "Test"))).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(1)
	local second: any = actions:RequestAction("Action.Attack")
	expect(second.accepted).toBe(true)
	actions:Destroy()
	expect(tags:GetActiveTags()[1].stackCount).toBe(2)
	TagControllerModule.Step(6)
	expect(tags:HasTag("Tag.Bleeding")).toBe(false)
end)

it("dispatches Tag events only after all declarative Tags and the Action are active", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { "Tag.Bleeding" },
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local observed: { string } = {}
	tags.OnTagAdded:Connect(function()
		if tags:HasTag("Tag.Blocking") and tags:HasTag("Tag.Bleeding") then
			table.insert(observed, "all tags visible")
		end
	end)
	actions.OnActionStarted:Connect(function()
		if tags:HasTag("Tag.Blocking") and tags:HasTag("Tag.Bleeding") then
			table.insert(observed, "started with tags")
		end
	end)
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(observed).toEqual({ "all tags visible", "all tags visible", "started with tags" })
end)

it("rejects when onCanStart adds a blocked Tag before final validation", function()
	local tags: TagController? = nil
	initialize({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			blockedTags = { "Tag.Stunned" },
			onCanStart = function(): (boolean, string?)
				(tags :: TagController):AddTag("Tag.Stunned")
				return true, nil
			end,
		},
	}, { tag("Tag.Stunned", "Ignore") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	local rejected: any = actions:RequestAction("Action.Dodge")
	expect(rejected.accepted).toBe(false)
	expect(rejected.reason).toBe("ActionBlockedTagPresent:Tag.Stunned")
	expect(rejected.sequenceId).toBeNil()
	expect(registeredTags:HasTag("Tag.Stunned")).toBe(true)
end)

it("revalidates Tag requirements after a preemption decision changes them", function()
	local tags: TagController? = nil
	local ownerContext: ActionTypes.ActionExecutionContext? = nil
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				ownerContext = context
			end,
			canBeInterruptedBy = function(): boolean
				(tags :: TagController):RemoveTag("Tag.Grounded")
				return true
			end,
		},
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			requiredTags = { "Tag.Grounded" },
		},
	}, { tag("Tag.Grounded", "Ignore") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	expect((registeredTags:AddTag("Tag.Grounded"))).toBe(true)
	expect(actions:RequestAction("Action.Block")).toEqual({ accepted = true, sequenceId = 1 })
	local rejected: any = actions:RequestAction("Action.Dodge")
	expect(rejected.accepted).toBe(false)
	expect(rejected.sequenceId).toBeNil()
	expect((ownerContext :: ActionTypes.ActionExecutionContext):IsActive()).toBe(true)
end)

it("cleans active Tags before interruption callbacks during preemption", function()
	local tags: TagController? = nil
	local observed: { string } = {}
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Action.Dodge" },
			activeTags = { "Tag.Blocking" },
			onInterrupt = function()
				if
					not (tags :: TagController):HasTag("Tag.Blocking")
					and (tags :: TagController):HasTag("Tag.Dodging")
				then
					table.insert(observed, "preempted after commit")
				end
			end,
		} :: any,
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			activeTags = { "Tag.Dodging" },
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Dodging", "Stack") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	expect(actions:RequestAction("Action.Block").accepted).toBe(true)
	expect(actions:RequestAction("Action.Dodge").accepted).toBe(true)
	expect(observed).toEqual({ "preempted after commit" })
end)

it("cleans active Tags before controller destruction callbacks", function()
	local tags: TagController? = nil
	local observedClean: boolean = false
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			onInterrupt = function()
				observedClean = not (tags :: TagController):HasTag("Tag.Blocking")
			end,
		} :: any,
	}, { tag("Tag.Blocking", "Stack") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	expect(actions:RequestAction("Action.Block").accepted).toBe(true)
	actions:Destroy()
	expect(observedClean).toBe(true)
	expect(registeredTags:HasTag("Tag.Blocking")).toBe(false)
end)

it("cleans active Tags after onStart fails while preserving applied Tags", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { "Tag.Bleeding" },
			onStart = function()
				error("start failed")
			end,
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local result: any = actions:RequestAction("Action.Block")
	expect(result.accepted).toBe(true)
	expect((actions:EndAction(result.sequenceId))).toBe(false)
	expect(tags:HasTag("Tag.Blocking")).toBe(false)
	expect(tags:HasTag("Tag.Bleeding")).toBe(true)
end)

it("leaves an existing Ignore Tag in place when active application was ignored", function()
	initialize(
		{ { id = "Action.Block", visibility = "ServerOnly", autoGrant = true, activeTags = { "Tag.Blocking" } } :: any },
		{ tag("Tag.Blocking", "Ignore") }
	)
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect((tags:AddTag("Tag.Blocking"))).toBe(true)
	local result: any = actions:RequestAction("Action.Block")
	expect(result.accepted).toBe(true)
	expect((actions:EndAction(result.sequenceId))).toBe(true)
	expect(tags:HasTag("Tag.Blocking")).toBe(true)
end)

it("rejects the whole activation when a later declarative Tag cannot be applied", function()
	local invalidateCatalog: boolean = true
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { "Tag.Bleeding" },
			onCanStart = function(): (boolean, string?)
				if invalidateCatalog then
					invalidateCatalog = false
					TagRegistry._resetForTests()
					expect((TagRegistry.Load({ tag("Tag.Blocking", "Stack") }))).toBe(true)
				end
				return true, nil
			end,
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local rejected: any = actions:RequestAction("Action.Attack")
	expect(rejected.accepted).toBe(false)
	expect(rejected.reason).toBe("ActionTagActivationFailed:Tag.Bleeding")
	expect(rejected.sequenceId).toBeNil()
	expect(tags:GetActiveTags()).toEqual({})
	TagRegistry._resetForTests()
	expect((TagRegistry.Load({ tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") }))).toBe(true)
	expect(actions:RequestAction("Action.Attack")).toEqual({ accepted = true, sequenceId = 1 })
end)

it("does not preempt a conflict owner when incoming Tag activation fails", function()
	local ownerContext: ActionTypes.ActionExecutionContext? = nil
	local decisionCalls: number = 0
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Action.Dodge" },
			activeTags = { "Tag.Blocking" },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				ownerContext = context
			end,
			canBeInterruptedBy = function(): boolean
				decisionCalls += 1
				TagRegistry._resetForTests()
				expect((TagRegistry.Load({ tag("Tag.Blocking", "Stack") }))).toBe(true)
				return true
			end,
		} :: any,
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			appliedTags = { "Tag.Bleeding" },
		} :: any,
		{ id = "Action.Idle", visibility = "ServerOnly", autoGrant = true },
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Action.Block")).toEqual({ accepted = true, sequenceId = 1 })
	local rejected: any = actions:RequestAction("Action.Dodge")
	expect(decisionCalls).toBe(1)
	expect(rejected.accepted).toBe(false)
	expect(rejected.reason).toBe("ActionTagActivationFailed:Tag.Bleeding")
	expect(rejected.sequenceId).toBeNil()
	expect((ownerContext :: ActionTypes.ActionExecutionContext):IsActive()).toBe(true)
	expect(tags:HasTag("Tag.Blocking")).toBe(true)
	expect(tags:HasTag("Tag.Bleeding")).toBe(false)
	expect(actions:RequestAction("Action.Idle")).toEqual({ accepted = true, sequenceId = 2 })
end)

it("allows a Tag event to request another Action against the fully committed Tag state", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking", "Tag.Ready" },
		} :: any,
		{
			id = "Action.Followup",
			visibility = "ServerOnly",
			autoGrant = true,
			requiredTags = { "Tag.Blocking", "Tag.Ready" },
		},
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Ready", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local nested: any = nil
	tags.OnTagAdded:Connect(function()
		if nested == nil then
			nested = actions:RequestAction("Action.Followup")
		end
	end)
	expect(actions:RequestAction("Action.Block")).toEqual({ accepted = true, sequenceId = 1 })
	expect(nested).toEqual({ accepted = true, sequenceId = 2 })
	local activeTags: { TagTypes.ActiveTagSnapshot } = tags:GetActiveTags()
	expect(activeTags[1].tagId).toBe("Tag.Blocking")
	expect(activeTags[2].tagId).toBe("Tag.Ready")
end)

it("preserves applied Tags when their Action is preempted", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Action.Dodge" },
			appliedTags = { "Tag.Bleeding" },
		} :: any,
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Hands" } },
	}, { tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(actions:RequestAction("Action.Dodge").accepted).toBe(true)
	expect(tags:HasTag("Tag.Bleeding")).toBe(true)
end)

it("preserves a later external Refresh application after active Tag cleanup", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { { id = "Tag.Blocking", duration = 2 } },
		} :: any,
	}, {
		{ id = "Tag.Blocking", visibility = "ServerOnly", duplicateBehavior = "Refresh" },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect((tags:AddTag("Tag.Blocking", { duration = 8 }))).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(tags:GetTagInstances("Tag.Blocking")[1].remainingDuration).toBe(8)
end)

it("preserves a later external stack after an active Tag was consumed", function()
	initialize(
		{ { id = "Action.Block", visibility = "ServerOnly", autoGrant = true, activeTags = { "Tag.Blocking" } } :: any },
		{ tag("Tag.Blocking", "Stack") }
	)
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect((tags:RemoveSingleTag("Tag.Blocking"))).toBe(true)
	expect((tags:AddTag("Tag.Blocking"))).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(tags:HasTag("Tag.Blocking")).toBe(true)
end)

it("dispatches terminal events after all active Tag cleanup commits", function()
	local context: ActionTypes.ActionExecutionContext? = nil
	local observations: { string } = {}
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking", "Tag.Ready" },
			onStart = function(startedContext: ActionTypes.ActionExecutionContext)
				context = startedContext
			end,
		} :: any,
	}, { tag("Tag.Blocking", "Stack"), tag("Tag.Ready", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	tags.OnTagRemoved:Connect(function()
		if
			not tags:HasTag("Tag.Blocking")
			and not tags:HasTag("Tag.Ready")
			and not (context :: ActionTypes.ActionExecutionContext):IsActive()
		then
			table.insert(observations, "tag removed after commit")
		end
	end)
	actions.OnActionEnded:Connect(function()
		if not tags:HasTag("Tag.Blocking") and not tags:HasTag("Tag.Ready") then
			table.insert(observations, "ended after commit")
		end
	end)
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(observations).toEqual({ "tag removed after commit", "tag removed after commit", "ended after commit" })
end)

it("lets Action code choose a later Tag reaction through normal lifecycle methods", function()
	local context: ActionTypes.ActionExecutionContext? = nil
	initialize({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			requiredTags = { "Tag.Grounded" },
			onStart = function(startedContext: ActionTypes.ActionExecutionContext)
				context = startedContext
			end,
		},
	}, { tag("Tag.Grounded", "Ignore") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect((tags:AddTag("Tag.Grounded"))).toBe(true)
	expect(actions:RequestAction("Action.Dodge").accepted).toBe(true)
	expect((tags:RemoveTag("Tag.Grounded"))).toBe(true)
	expect((context :: ActionTypes.ActionExecutionContext):IsActive()).toBe(true)
	expect((context :: ActionTypes.ActionExecutionContext):Interrupt("LostGrounded")).toBe(true)
	expect((context :: ActionTypes.ActionExecutionContext):IsActive()).toBe(false)
end)

it("cleans active Tags when an update failure interrupts the Action", function()
	local tags: TagController? = nil
	local observedClean: boolean = false
	initialize({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Channeling" },
			appliedTags = { "Tag.Bleeding" },
			onUpdate = function()
				error("update failed")
			end,
			onInterrupt = function()
				observedClean = not (tags :: TagController):HasTag("Tag.Channeling")
					and (tags :: TagController):HasTag("Tag.Bleeding")
			end,
		} :: any,
	}, { tag("Tag.Channeling", "Stack"), tag("Tag.Bleeding", "Stack") })
	local _actor: Actor, actions: ActionController, registeredTags: TagController = registerActor()
	tags = registeredTags
	local started: any = actions:RequestAction("Action.Channel")
	expect(started.accepted).toBe(true)
	now += 1
	ActionControllerUpdates._heartbeatForTests(1)
	expect(observedClean).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(false)
end)

it("dispatches Interrupted after active Tag cleanup and preserves applied Tags", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { "Tag.Bleeding" },
		} :: any,
	}, {
		tag("Tag.Blocking", "Stack"),
		tag("Tag.Bleeding", "Stack"),
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local observed: boolean = false
	actions.OnActionInterrupted:Connect(function()
		observed = not tags:HasTag("Tag.Blocking") and tags:HasTag("Tag.Bleeding")
	end)
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect((actions:InterruptAction(started.sequenceId, "Test"))).toBe(true)
	expect(observed).toBe(true)
end)
