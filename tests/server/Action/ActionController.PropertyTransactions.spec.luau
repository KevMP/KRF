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
local PropertyTypes = require(KRF.server.Property.types)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController
type TagDefinition = TagTypes.TagDefinition

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

for _, trigger: string in { "Started", "TagAdded" } do
	it("drains older Property notifications first when " .. trigger .. " changes the base synchronously", function()
		local order: { string } = {}
		initialize({
			{
				id = "Haste",
				visibility = "ServerOnly",
				autoGrant = true,
				activeTags = { "Haste" },
				onStart = function()
					table.insert(order, "hook")
				end,
			},
		}, {
			{
				id = "Haste",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { WalkSpeed = { add = 5 } },
			},
		})
		local actor: Actor, actions: ActionController, tags: TagController = registerActor()
		local properties: PropertyTypes.PropertyController =
			actor:GetController("PropertyController") :: PropertyTypes.PropertyController
		local observed: number? = nil
		local mutationResult: boolean? = nil
		local mutationReason: string? = nil
		local function mutate(): ()
			observed = properties:GetResolvedProperty("WalkSpeed")
			mutationResult, mutationReason = properties:SetBaseProperty("WalkSpeed", 20)
			table.insert(order, "nested returned")
		end
		properties.OnBasePropertyChanged:Connect(function(_actor: Actor, _name: string, old: number?, new: number)
			table.insert(order, `base {old}->{new}`)
		end)
		properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, _name: string, old: number?, new: number)
			table.insert(order, `resolved {old}->{new}`)
		end)
		properties.OnPropertyChanged:Connect(function(change: PropertyTypes.PropertyChange)
			table.insert(order, `umbrella {change.oldResolvedValue}->{change.newResolvedValue}`)
		end)
		actions.OnActionStarted:Connect(function()
			table.insert(order, "Started")
			if trigger == "Started" then
				mutate()
			end
		end)
		tags.OnTagAdded:Connect(function()
			table.insert(order, "TagAdded")
			if trigger == "TagAdded" then
				mutate()
			end
		end)
		expect(actions:RequestAction("Haste")).toEqual({ accepted = true, sequenceId = 1 })
		expect(observed).toBe(21)
		expect(mutationResult).toBe(true)
		expect(mutationReason).toBeNil()
		expect(properties:GetResolvedProperty("WalkSpeed")).toBe(25)
		local expected: { string } = { "Started" }
		if trigger == "TagAdded" then
			table.insert(expected, "TagAdded")
		end
		for _, event: string in
			{
				"resolved 16->21",
				"umbrella 16->21",
				"base 16->20",
				"resolved 21->25",
				"umbrella 21->25",
				"nested returned",
			}
		do
			table.insert(expected, event)
		end
		if trigger == "Started" then
			table.insert(expected, "TagAdded")
		end
		table.insert(expected, "hook")
		expect(order).toEqual(expected)
	end)
end

for _, trigger: string in { "base", "resolved", "umbrella" } do
	it("recursively drains every older signal when a " .. trigger .. " listener changes a Property", function()
		initialize({}, {})
		local actor: Actor, _actions: ActionController, _tags: TagController = registerActor()
		local properties: PropertyTypes.PropertyController =
			actor:GetController("PropertyController") :: PropertyTypes.PropertyController
		local order: { string } = {}
		local nestedOrder: { string } = {}
		local nestedResult: boolean? = nil
		local function observe(kind: string, newValue: number): ()
			table.insert(order, `{kind} {newValue}`)
			if kind == trigger and newValue == 20 then
				nestedResult = properties:SetBaseProperty("WalkSpeed", 30)
				nestedOrder = table.clone(order)
			end
		end
		properties.OnBasePropertyChanged:Connect(function(_actor: Actor, _name: string, _old: number?, new: number)
			observe("base", new)
		end)
		properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, _name: string, _old: number?, new: number)
			observe("resolved", new)
		end)
		properties.OnPropertyChanged:Connect(function(change: PropertyTypes.PropertyChange)
			observe("umbrella", change.newResolvedValue)
		end)
		expect((properties:SetBaseProperty("WalkSpeed", 20))).toBe(true)
		expect(nestedResult).toBe(true)
		local expected: { string } =
			{ "base 20", "resolved 20", "umbrella 20", "base 30", "resolved 30", "umbrella 30" }
		expect(order).toEqual(expected)
		expect(nestedOrder).toEqual(expected)
		expect(properties:GetResolvedProperty("WalkSpeed")).toBe(30)
	end)
end

it("dispatches lifecycle, Tag, Property, and hook events after committing every affected cache", function()
	local order: { string } = {}
	initialize({
		{
			id = "Buff",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Speed", "Jump" },
			onStart = function()
				table.insert(order, "hook")
			end,
		},
	}, {
		{
			id = "Speed",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
		{
			id = "Jump",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { JumpPower = { add = 10 } },
		},
	})
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	local snapshots: { { [string]: number } } = {}
	local function observe(label: string): ()
		table.insert(order, label)
		table.insert(snapshots, properties:GetResolvedProperties())
	end
	actions.OnActionStarted:Connect(function()
		observe("Started")
	end)
	tags.OnTagAdded:Connect(function(_actor: Actor, tagId: string)
		observe(tagId)
	end)
	properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, name: string)
		observe("resolved " .. name)
	end)
	properties.OnPropertyChanged:Connect(function(change: PropertyTypes.PropertyChange)
		observe("umbrella " .. change.propertyName)
	end)
	expect(actions:RequestAction("Buff").accepted).toBe(true)
	expect(order).toEqual({
		"Started",
		"Speed",
		"Jump",
		"resolved JumpPower",
		"umbrella JumpPower",
		"resolved WalkSpeed",
		"umbrella WalkSpeed",
		"hook",
	})
	expect(#snapshots).toBe(7)
	for _, snapshot: { [string]: number } in snapshots do
		expect(snapshot).toEqual({ WalkSpeed = 21, JumpPower = 60 })
	end
end)

it("publishes no Property change when preemption replaces a modifier with an equal contribution", function()
	initialize({
		{
			id = "Old",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "New" },
			activeTags = { "OldHaste" },
		},
		{
			id = "New",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			activeTags = { "NewHaste" },
		},
	}, {
		{
			id = "OldHaste",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
		{
			id = "NewHaste",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	expect(actions:RequestAction("Old").accepted).toBe(true)
	local notifications: number = 0
	local values: { number? } = {}
	local function observe(): ()
		table.insert(values, properties:GetResolvedProperty("WalkSpeed"))
	end
	properties.OnResolvedPropertyChanged:Connect(function()
		notifications += 1
	end)
	properties.OnPropertyChanged:Connect(function()
		notifications += 1
	end)
	actions.OnActionInterrupted:Connect(observe)
	actions.OnActionStarted:Connect(observe)
	tags.OnTagRemoved:Connect(observe)
	tags.OnTagAdded:Connect(observe)
	expect(actions:RequestAction("New")).toEqual({ accepted = true, sequenceId = 2 })
	expect(values).toEqual({ 21, 21, 21, 21 })
	expect(notifications).toBe(0)
end)

it("orders activation and cleanup Property changes when Started synchronously ends the Action", function()
	initialize({ { id = "Haste", visibility = "ServerOnly", autoGrant = true, activeTags = { "Haste" } } }, {
		{
			id = "Haste",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, _tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	local values: { number? } = {}
	local order: { string } = {}
	local beforeReturn: { string } = {}
	local ended: boolean? = nil
	properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, _name: string, old: number?, new: number)
		table.insert(order, `resolved {old}->{new}`)
		table.insert(values, properties:GetResolvedProperty("WalkSpeed"))
	end)
	properties.OnPropertyChanged:Connect(function(change: PropertyTypes.PropertyChange)
		table.insert(order, `umbrella {change.oldResolvedValue}->{change.newResolvedValue}`)
	end)
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		ended = actions:EndAction(event.sequenceId)
		beforeReturn = table.clone(order)
	end)
	expect(actions:RequestAction("Haste")).toEqual({ accepted = true, sequenceId = 1 })
	expect(ended).toBe(true)
	expect(order).toEqual({ "resolved 16->21", "umbrella 16->21", "resolved 21->16", "umbrella 21->16" })
	expect(beforeReturn).toEqual(order)
	expect(values).toEqual({ 16, 16 })
end)

it("discards pending Property notifications when a Tag listener destroys the Property controller", function()
	initialize({ { id = "Haste", visibility = "ServerOnly", autoGrant = true, activeTags = { "Haste" } } }, {
		{
			id = "Haste",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	local notifications: number = 0
	properties.OnResolvedPropertyChanged:Connect(function()
		notifications += 1
	end)
	properties.OnPropertyChanged:Connect(function()
		notifications += 1
	end)
	tags.OnTagAdded:Connect(function()
		properties:Destroy()
	end)
	expect(actions:RequestAction("Haste")).toEqual({ accepted = true, sequenceId = 1 })
	expect((actions:EndAction(1))).toBe(true)
	expect(notifications).toBe(0)
	expect(properties:GetResolvedProperty("WalkSpeed")).toBe(21)
end)

it("keeps Property transitions ordered when a Property listener synchronously starts an Action", function()
	initialize({ { id = "Haste", visibility = "ServerOnly", autoGrant = true, activeTags = { "Haste" } } }, {
		{
			id = "Haste",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, _tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	local order: { string } = {}
	local nested: ActionTypes.ActionRequestResult? = nil
	local beforeReturn: { string } = {}
	properties.OnBasePropertyChanged:Connect(function()
		table.insert(order, "base")
		nested = actions:RequestAction("Haste")
		beforeReturn = table.clone(order)
	end)
	properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, _name: string, old: number?, new: number)
		table.insert(order, `resolved {old}->{new}`)
	end)
	properties.OnPropertyChanged:Connect(function(change: PropertyTypes.PropertyChange)
		table.insert(order, `umbrella {change.oldResolvedValue}->{change.newResolvedValue}`)
	end)
	expect((properties:SetBaseProperty("WalkSpeed", 20))).toBe(true)
	expect(nested).toEqual({ accepted = true, sequenceId = 1 })
	expect(order).toEqual({ "base", "resolved 16->20", "umbrella 16->20", "resolved 20->25", "umbrella 20->25" })
	expect(beforeReturn).toEqual(order)
end)
