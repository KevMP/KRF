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
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTestUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type ActionDefinition = ActionTypes.ActionDefinition
type ResourceController = ResourceTypes.ResourceController
type PropertyController = PropertyTypes.PropertyController
type TagController = TagTypes.TagController
type ResourceChange = ResourceTypes.ResourceChange

beforeEach(ResourceTestUtils.reset)
afterEach(ResourceTestUtils.cleanup)

local mana: ResourceTypes.ResourceDefinition = {
	id = "Mana",
	visibility = "ServerOnly",
	autoAssign = true,
	min = { propertyName = "MinMana", defaultBaseValue = 0 },
	max = { propertyName = "MaxMana", defaultBaseValue = 100 },
	initialValue = 100,
	regen = { rate = { propertyName = "ManaRegen", defaultBaseValue = 2 } },
}

for _, mutation: string in { "current", "requirement", "bounds", "multiplier" } do
	it("revalidates " .. mutation .. " changed by a later AC5 decision without partial preemption", function()
		local contexts: { ActionTypes.ActionExecutionContext } = {}
		local definitions: { ActionDefinition } = {}
		local decisions: { string } = {}
		for _, name: string in { "Hands", "Movement" } do
			table.insert(definitions, {
				id = name,
				visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
				autoGrant = true,
				locks = { name },
				interruptibleBy = { "Incoming" },
				activeTags = { name },
				onStart = function(context: ActionTypes.ActionExecutionContext)
					table.insert(contexts, context)
				end,
				canBeInterruptedBy = function(context: ActionTypes.ActionExecutionContext): boolean
					table.insert(decisions, name)
					if name == "Movement" then
						local resources: ResourceController =
							context.actor:GetController("ResourceController") :: ResourceController
						local properties: PropertyController =
							context.actor:GetController("PropertyController") :: PropertyController
						if mutation == "current" or mutation == "requirement" then
							expect((resources:SetCurrent("Mana", 10))).toBe(true)
						elseif mutation == "bounds" then
							expect((properties:SetBaseProperty("MaxMana", 1000))).toBe(true)
						else
							expect((properties:SetBaseProperty("Multiplier", 10))).toBe(true)
						end
					end
					return true
				end,
			})
		end
		table.insert(definitions, {
			id = "Incoming",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Movement", "Hands" },
			activeTags = { "Incoming" },
			appliedTags = { "Applied" },
			resourceRequirements = if mutation == "requirement" then { Mana = { min = 100 } } else nil,
			costs = {
				Mana = if mutation == "bounds"
					then { percent = 0.25 }
					elseif mutation == "multiplier" then { amount = 20, multiplierProperty = "Multiplier" }
					elseif mutation == "requirement" then 5
					else 20,
			},
		})
		table.insert(definitions, {
			id = "Probe",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands", "Movement" },
		})
		table.insert(
			definitions,
			{ id = "Idle", visibility = "ServerOnly" :: ActionTypes.ActionVisibility, autoGrant = true }
		)
		ResourceTestUtils.initialize(definitions, { mana }, {
			{ id = "Hands", visibility = "ServerOnly", duplicateBehavior = "Stack" },
			{ id = "Movement", visibility = "ServerOnly", duplicateBehavior = "Stack" },
			{ id = "Incoming", visibility = "ServerOnly", duplicateBehavior = "Stack" },
			{ id = "Applied", visibility = "ServerOnly", duplicateBehavior = "Stack" },
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController, tags: TagController =
			ResourceTestUtils.registerActor()
		expect((properties:SetBaseProperty("Multiplier", 1))).toBe(true)
		expect(actions:RequestAction("Hands")).toEqual({ accepted = true, sequenceId = 1 })
		expect(actions:RequestAction("Movement")).toEqual({ accepted = true, sequenceId = 2 })
		local interrupted: number = 0
		local tagChanges: number = 0
		actions.OnActionInterrupted:Connect(function()
			interrupted += 1
		end)
		tags.OnTagChanged:Connect(function()
			tagChanges += 1
		end)
		ResourceTestUtils.expectRejected(actions:RequestAction("Incoming"))
		expect(decisions).toEqual({ "Hands", "Movement" })
		expect(contexts[1]:IsActive()).toBe(true)
		expect(contexts[2]:IsActive()).toBe(true)
		expect(tags:HasTag("Hands")).toBe(true)
		expect(tags:HasTag("Movement")).toBe(true)
		expect(tags:HasTag("Incoming")).toBe(false)
		expect(tags:HasTag("Applied")).toBe(false)
		expect(resources:GetCurrent("Mana")).toBe(
			if mutation == "current" or mutation == "requirement" then 10 else 100
		)
		expect(interrupted).toBe(0)
		expect(tagChanges).toBe(0)
		expect(actions:RequestAction("Probe")).toEqual({ accepted = false, reason = "ActionLockConflict" })
		expect(actions:RequestAction("Idle")).toEqual({ accepted = true, sequenceId = 3 })
	end)
end

it("validates every declared cost before spending even when another Resource is affordable", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20, Chakra = 10 } },
	}, {
		mana,
		{ id = "Chakra", visibility = "ServerOnly", autoAssign = true, max = { value = 10 }, initialValue = 5 },
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local changes: { ResourceChange } = {}
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))).toBe(reason)
	expect(resources:GetCurrent("Mana")).toBe(100)
	expect(resources:GetCurrent("Chakra")).toBe(5)
	expect(changes).toEqual({})
	expect((resources:Restore("Chakra", 5))).toBe(true)
	changes = {}
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(resources:GetCurrent("Mana")).toBe(80)
	expect(resources:GetCurrent("Chakra")).toBe(0)
	expect(#changes).toBe(2)
end)

it("commits all owners, incoming locks, Tags, Properties and Resources before the first callback", function()
	local contexts: { ActionTypes.ActionExecutionContext } = {}
	local definitions: { ActionDefinition } = {}
	local order: { string } = {}
	for _, name: string in { "Hands", "Movement" } do
		table.insert(definitions, {
			id = name,
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { name },
			interruptibleBy = { "Incoming" },
			activeTags = { name },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				table.insert(contexts, context)
			end,
			onInterrupt = function()
				table.insert(order, "hook " .. name)
			end,
		})
	end
	table.insert(definitions, {
		id = "Incoming",
		visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
		autoGrant = true,
		locks = { "Movement", "Hands" },
		activeTags = { "Incoming" },
		costs = { Mana = 75, Chakra = 20 },
		onStart = function()
			table.insert(order, "incoming hook")
		end,
	})
	table.insert(definitions, {
		id = "Probe",
		visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
		autoGrant = true,
		locks = { "Hands", "Movement" },
	})
	ResourceTestUtils.initialize(
		definitions,
		{ mana, { id = "Chakra", visibility = "ServerOnly", autoAssign = true, max = { value = 100 } } },
		{
			{
				id = "Hands",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { MaxMana = { add = 50 } },
			},
			{
				id = "Movement",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { ManaRegen = { set = 4 } },
			},
			{
				id = "Incoming",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { MinMana = { set = 10 }, MaxMana = { set = 60 }, ManaRegen = { set = 3 } },
			},
		}
	)
	local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController, tags: TagController =
		ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Hands")).toEqual({ accepted = true, sequenceId = 1 })
	expect(actions:RequestAction("Movement")).toEqual({ accepted = true, sequenceId = 2 })
	expect((resources:SetCurrent("Mana", 150))).toBe(true)
	local observations: { boolean } = {}
	local probes: { ActionTypes.ActionRequestResult } = {}
	local changes: { ResourceChange } = {}
	local function observe(): ()
		table.insert(
			observations,
			not contexts[1]:IsActive()
				and not contexts[2]:IsActive()
				and not tags:HasTag("Hands")
				and not tags:HasTag("Movement")
				and tags:HasTag("Incoming")
				and properties:GetResolvedProperty("MinMana") == 10
				and properties:GetResolvedProperty("MaxMana") == 60
				and resources:GetMin("Mana") == 10
				and resources:GetMax("Mana") == 60
				and resources:GetCurrent("Mana") == 60
				and resources:GetCurrent("Chakra") == 80
		)
		table.insert(probes, actions:RequestAction("Probe"))
	end
	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		observe()
		table.insert(order, "Interrupted " .. event.actionId)
	end)
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		if event.actionId == "Incoming" then
			observe()
			table.insert(order, "Started")
		end
	end)
	tags.OnTagRemoved:Connect(function(_actor: Actor, id: string)
		observe()
		table.insert(order, "Removed " .. id)
	end)
	tags.OnTagAdded:Connect(function(_actor: Actor, id: string)
		observe()
		table.insert(order, "Added " .. id)
	end)
	properties.OnResolvedPropertyChanged:Connect(function(_actor: Actor, name: string)
		observe()
		table.insert(order, "Property " .. name)
	end)
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		observe()
		table.insert(changes, change)
		table.insert(order, "Resource " .. change.resourceId)
	end)
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = true, sequenceId = 3 })
	expect(#observations).toBe(11)
	for _, observed: boolean in observations do
		expect(observed).toBe(true)
	end
	for _, probe: ActionTypes.ActionRequestResult in probes do
		expect(probe).toEqual({ accepted = false, reason = "ActionLockConflict" })
	end
	expect(order).toEqual({
		"Interrupted Hands",
		"Interrupted Movement",
		"Started",
		"Removed Hands",
		"Removed Movement",
		"Added Incoming",
		"Property ManaRegen",
		"Property MaxMana",
		"Property MinMana",
		"Resource Chakra",
		"Resource Mana",
		"hook Hands",
		"hook Movement",
		"incoming hook",
	})
	expect(changes[1].currentOldValue).toBe(100)
	expect(changes[1].currentNewValue).toBe(80)
	expect(changes[2]).toEqual({
		actor = _actor,
		resourceId = "Mana",
		currentOldValue = 150,
		currentNewValue = 60,
		minOldValue = 0,
		minNewValue = 10,
		maxOldValue = 150,
		maxNewValue = 60,
	})
end)

for _, bound: string in { "MinMana", "MaxMana" } do
	it("keeps the prepared percentage price when an incoming Tag changes " .. bound, function()
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = { percent = 0.75 } },
				resourceRequirements = { Mana = { min = 100 } },
				activeTags = { "Bound" },
			},
		}, { mana }, {
			{
				id = "Bound",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { [bound] = { set = 50 } },
			},
		})
		local actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
		local changes: { ResourceChange } = {}
		local observed: { number? } = {}
		actions.OnActionStarted:Connect(function()
			table.insert(observed, resources:GetCurrent("Mana"))
		end)
		resources.OnResourceChanged:Connect(function(change: ResourceChange)
			table.insert(changes, change)
		end)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		local finalCurrent: number = if bound == "MinMana" then 50 else 25
		expect(observed).toEqual({ finalCurrent })
		expect(changes).toEqual({
			{
				actor = actor,
				resourceId = "Mana",
				currentOldValue = 100,
				currentNewValue = finalCurrent,
				minOldValue = 0,
				minNewValue = if bound == "MinMana" then 50 else 0,
				maxOldValue = 100,
				maxNewValue = if bound == "MaxMana" then 50 else 100,
			},
		})
		expect((actions:EndAction(1))).toBe(true)
		expect(resources:GetCurrent("Mana")).toBe(finalCurrent)
	end)
end

it("preserves last valid bounds and regen after invalid final range while keeping the prepared spend", function()
	local observed: { number? } = {}
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			activeTags = { "InvalidRange" },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				local resources: ResourceController =
					context.actor:GetController("ResourceController") :: ResourceController
				resources:Step(1)
			end,
		},
	}, { mana }, {
		{
			id = "InvalidRange",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MinMana = { set = 150 }, ManaRegen = { set = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
		ResourceTestUtils.registerActor()
	local changes: { ResourceChange } = {}
	actions.OnActionStarted:Connect(function()
		table.insert(observed, properties:GetResolvedProperty("MinMana"))
		table.insert(observed, properties:GetResolvedProperty("ManaRegen"))
		table.insert(observed, resources:GetMin("Mana"))
		table.insert(observed, resources:GetMax("Mana"))
		table.insert(observed, resources:GetCurrent("Mana"))
	end)
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(observed).toEqual({ 150, 5, 0, 100, 80 })
	expect(resources:GetCurrent("Mana")).toBe(82)
	expect(changes).toEqual({
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 100,
			currentNewValue = 80,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 100,
			maxNewValue = 100,
		},
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 80,
			currentNewValue = 82,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 100,
			maxNewValue = 100,
		},
	})
	expect((actions:EndAction(1))).toBe(true)
	expect(resources:GetCurrent("Mana")).toBe(82)
	expect(resources:GetMin("Mana")).toBe(0)
	expect(properties:GetResolvedProperty("MinMana")).toBe(0)
end)

for _, source: string in { "incoming", "preempted" } do
	it("does not reprice the Action from " .. source .. " Tag changes to its multiplier", function()
		ResourceTestUtils.initialize({
			{
				id = "Owner",
				visibility = "ServerOnly",
				autoGrant = true,
				locks = { "Hands" },
				interruptibleBy = { "Cast" },
				activeTags = { "Discount" },
			},
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				locks = { "Hands" },
				costs = { Mana = { amount = 40, multiplierProperty = "Multiplier" } },
				activeTags = if source == "incoming" then { "Discount" } else nil,
			},
		}, { mana }, {
			{
				id = "Discount",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { Multiplier = { multiply = 0.5 } },
			},
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
			ResourceTestUtils.registerActor()
		expect((properties:SetBaseProperty("Multiplier", 1))).toBe(true)
		if source == "preempted" then
			expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
		end
		expect(actions:RequestAction("Cast")).toEqual({
			accepted = true,
			sequenceId = if source == "preempted" then 2 else 1,
		})
		expect(resources:GetCurrent("Mana")).toBe(if source == "preempted" then 80 else 60)
		expect(properties:GetResolvedProperty("Multiplier")).toBe(if source == "preempted" then 1 else 0.5)
	end)
end

it("does not reprice a percentage cost when preemption removes a Resource capacity modifier", function()
	ResourceTestUtils.initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Cast" },
			activeTags = { "Capacity" },
		},
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			costs = { Mana = { percent = 0.5 } },
		},
	}, { mana }, {
		{
			id = "Capacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { add = 100 } },
		},
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect((resources:SetCurrent("Mana", 200))).toBe(true)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 2 })
	expect(resources:GetCurrent("Mana")).toBe(100)
	expect(resources:GetMax("Mana")).toBe(100)
end)

it("replaces equivalent Resource-bound modifiers without intermediate clamp or fake notification", function()
	ResourceTestUtils.initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Cast" },
			activeTags = { "OldCapacity" },
		},
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			activeTags = { "NewCapacity" },
		},
	}, { mana }, {
		{
			id = "OldCapacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { add = 50 } },
		},
		{
			id = "NewCapacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { add = 50 } },
		},
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect((resources:SetCurrent("Mana", 150))).toBe(true)
	local changes: { ResourceChange } = {}
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 2 })
	expect(resources:GetMax("Mana")).toBe(150)
	expect(resources:GetCurrent("Mana")).toBe(150)
	expect(changes).toEqual({})
end)
