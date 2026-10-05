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
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local TagControllerModule = require(KRF.server.Tags.TagController)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController
type TagDefinition = TagTypes.TagDefinition
type PropertyController = PropertyTypes.PropertyController

local actors: { Actor } = {}
local models: { Model } = {}

beforeEach(function()
	Server._ResetForTests()
	TagControllerModule._setAutomaticSteppingEnabledForTests(false)
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

it("uses the Tag Runtime's Stack and maxStacks behavior across activations", function()
	initialize({
		{ id = "Action.Attack", visibility = "ServerOnly", autoGrant = true, appliedTags = { "Tag.Bleeding" } } :: any,
	}, {
		{
			id = "Tag.Bleeding",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			defaultDuration = 5,
			maxStacks = 2,
		},
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	TagControllerModule.Step(1)
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(2)
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(2)
	local instances: { TagTypes.TagInstanceSnapshot } = tags:GetTagInstances("Tag.Bleeding")
	expect(instances[1].remainingDuration).toBe(5)
	expect(instances[2].remainingDuration).toBe(5)
end)

it("refreshes an Action-applied Refresh Tag without creating another instance", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			appliedTags = { { id = "Tag.Bleeding", duration = 6 } },
		} :: any,
	}, {
		{ id = "Tag.Bleeding", visibility = "ServerOnly", duplicateBehavior = "Refresh", defaultDuration = 2 },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	TagControllerModule.Step(2)
	expect(tags:GetTagInstances("Tag.Bleeding")[1].remainingDuration).toBe(4)
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(#tags:GetTagInstances("Tag.Bleeding")).toBe(1)
	expect(tags:GetTagInstances("Tag.Bleeding")[1].remainingDuration).toBe(6)
end)

it("does not change an existing Ignore Tag when an Action reapplies it", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			appliedTags = { { id = "Tag.Shielded", duration = 6 } },
		} :: any,
	}, {
		{ id = "Tag.Shielded", visibility = "ServerOnly", duplicateBehavior = "Ignore" },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect((tags:AddTag("Tag.Shielded", { duration = 2 }))).toBe(true)
	local changed: number = 0
	tags.OnTagChanged:Connect(function()
		changed += 1
	end)
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(tags:GetTagInstances("Tag.Shielded")[1].duration).toBe(2)
	expect(#tags:GetTagInstances("Tag.Shielded")).toBe(1)
	expect(changed).toBe(0)
end)

it("uses Tag default duration when omitted and explicit duration when provided", function()
	initialize({
		{ id = "Action.Default", visibility = "ServerOnly", autoGrant = true, appliedTags = { "Tag.Bleeding" } } :: any,
		{
			id = "Action.Override",
			visibility = "ServerOnly",
			autoGrant = true,
			appliedTags = { { id = "Tag.Bleeding", duration = 8 } },
		} :: any,
	}, { { id = "Tag.Bleeding", visibility = "ServerOnly", duplicateBehavior = "Stack", defaultDuration = 3 } })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Action.Default").accepted).toBe(true)
	expect(actions:RequestAction("Action.Override").accepted).toBe(true)
	local instances: { TagTypes.TagInstanceSnapshot } = tags:GetTagInstances("Tag.Bleeding")
	expect(instances[1].duration).toBe(3)
	expect(instances[2].duration).toBe(8)
end)

it("ticks and expires an Action-applied Tag while updating Property modifiers", function()
	local tickCount: number = 0
	initialize(
		{ { id = "Action.Attack", visibility = "ServerOnly", autoGrant = true, appliedTags = { "Tag.Haste" } } :: any },
		{
			{
				id = "Tag.Haste",
				visibility = "ServerOnly",
				duplicateBehavior = "Ignore",
				defaultDuration = 2,
				tickInterval = 1,
				properties = { WalkSpeed = { add = 5 } },
				onTick = function(_actor: Actor, _deltaTime: number)
					tickCount += 1
				end,
			},
		}
	)
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local properties: PropertyController = actor:GetController("PropertyController") :: PropertyController
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(21)
	TagControllerModule.Step(1)
	expect(tickCount).toBe(1)
	expect(tags:HasTag("Tag.Haste")).toBe(true)
	TagControllerModule.Step(1)
	expect(tickCount).toBe(2)
	expect(tags:HasTag("Tag.Haste")).toBe(false)
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(16)
end)

it("applies declarative Tags only to the owning Actor", function()
	initialize({
		{
			id = "Action.Attack",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking" },
			appliedTags = { "Tag.Bleeding" },
		} :: any,
	}, {
		{ id = "Tag.Blocking", visibility = "ServerOnly", duplicateBehavior = "Stack" },
		{ id = "Tag.Bleeding", visibility = "ServerOnly", duplicateBehavior = "Stack" },
	})
	local _firstActor: Actor, actions: ActionController, firstTags: TagController = registerActor()
	local _secondActor: Actor, _secondActions: ActionController, secondTags: TagController = registerActor()
	expect(actions:RequestAction("Action.Attack").accepted).toBe(true)
	expect(firstTags:HasTag("Tag.Blocking")).toBe(true)
	expect(firstTags:HasTag("Tag.Bleeding")).toBe(true)
	expect(secondTags:GetActiveTags()).toEqual({})
end)

it("does not remove later unrelated Tag state after an active Tag expires", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { { id = "Tag.Blocking", duration = 1 } },
		} :: any,
	}, {
		{ id = "Tag.Blocking", visibility = "ServerOnly", duplicateBehavior = "Stack" },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	TagControllerModule.Step(1)
	expect(tags:HasTag("Tag.Blocking")).toBe(false)
	expect((tags:AddTag("Tag.Blocking"))).toBe(true)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(tags:HasTag("Tag.Blocking")).toBe(true)
end)

it("retains ownership when two active applications refresh the same new Tag", function()
	initialize({
		{
			id = "Action.Block",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Blocking", { id = "Tag.Blocking", duration = 4 } },
		} :: any,
	}, {
		{ id = "Tag.Blocking", visibility = "ServerOnly", duplicateBehavior = "Refresh" },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local started: any = actions:RequestAction("Action.Block")
	expect(started.accepted).toBe(true)
	expect(#tags:GetTagInstances("Tag.Blocking")).toBe(1)
	expect(tags:GetTagInstances("Tag.Blocking")[1].duration).toBe(4)
	expect((actions:EndAction(started.sequenceId))).toBe(true)
	expect(tags:HasTag("Tag.Blocking")).toBe(false)
end)

it("preserves the applied contribution when both fields use the same Tag", function()
	initialize({
		{
			id = "Action.Stack",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Stack" },
			appliedTags = { "Tag.Stack" },
		} :: any,
		{
			id = "Action.Refresh",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Tag.Refresh" },
			appliedTags = { "Tag.Refresh" },
		} :: any,
	}, {
		{ id = "Tag.Stack", visibility = "ServerOnly", duplicateBehavior = "Stack" },
		{ id = "Tag.Refresh", visibility = "ServerOnly", duplicateBehavior = "Refresh" },
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local stacked: any = actions:RequestAction("Action.Stack")
	expect(stacked.accepted).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(2)
	expect((actions:EndAction(stacked.sequenceId))).toBe(true)
	expect(tags:GetActiveTags()[1].stackCount).toBe(1)
	local refreshed: any = actions:RequestAction("Action.Refresh")
	expect(refreshed.accepted).toBe(true)
	expect((actions:EndAction(refreshed.sequenceId))).toBe(true)
	expect(tags:HasTag("Tag.Refresh")).toBe(true)
end)
