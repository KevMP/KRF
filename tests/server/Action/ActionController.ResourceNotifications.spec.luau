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
	max = { propertyName = "MaxMana", defaultBaseValue = 100 },
}

for _, trigger: string in { "Started", "TagAdded", "Property" } do
	it("drains the pending cost before a direct Resource mutation from " .. trigger .. " returns", function()
		local order: { string } = {}
		ResourceTestUtils.initialize({
			{
				id = "Cast",
				visibility = "ServerOnly",
				autoGrant = true,
				costs = { Mana = 20 },
				activeTags = { "Capacity" },
				onStart = function()
					table.insert(order, "hook")
				end,
			},
		}, { mana }, {
			{
				id = "Capacity",
				visibility = "ServerOnly",
				duplicateBehavior = "Stack",
				properties = { MaxMana = { set = 90 } },
			},
		})
		local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController, tags: TagController =
			ResourceTestUtils.registerActor()
		local beforeReturn: { string } = {}
		local succeeded: boolean? = nil
		local reason: string? = nil
		local function mutate(): ()
			succeeded, reason = resources:Spend("Mana", 10)
			beforeReturn = table.clone(order)
			table.insert(order, "nested returned")
		end
		resources.OnResourceChanged:Connect(function(change: ResourceChange)
			table.insert(order, `Resource {change.currentOldValue}->{change.currentNewValue}`)
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
		properties.OnResolvedPropertyChanged:Connect(function()
			table.insert(order, "Property")
			if trigger == "Property" then
				mutate()
			end
		end)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		expect(succeeded).toBe(true)
		expect(reason).toBeNil()
		expect(resources:GetCurrent("Mana")).toBe(70)
		local expected: { string } = { "Started" }
		if trigger ~= "Started" then
			table.insert(expected, "TagAdded")
		end
		if trigger == "Property" then
			table.insert(expected, "Property")
		end
		table.insert(expected, "Resource 100->80")
		table.insert(expected, "Resource 80->70")
		expect(beforeReturn).toEqual(expected)
		table.insert(expected, "nested returned")
		if trigger == "Started" then
			table.insert(expected, "TagAdded")
		end
		if trigger ~= "Property" then
			table.insert(expected, "Property")
		end
		table.insert(expected, "hook")
		expect(order).toEqual(expected)
	end)
end

for _, method: string in { "Spend", "Restore", "Drain", "SetCurrent" } do
	it("keeps public " .. method .. " synchronous during a pending Action transaction notification", function()
		ResourceTestUtils.initialize({
			{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20 } },
		}, { mana })
		local _actor: Actor, actions: ActionController, resources: ResourceController =
			ResourceTestUtils.registerActor()
		local changes: { { number } } = {}
		local beforeReturn: { { number } } = {}
		local mutationSucceeded: boolean? = nil
		local mutationReason: string? = nil
		resources.OnResourceChanged:Connect(function(change: ResourceChange)
			table.insert(changes, { change.currentOldValue, change.currentNewValue })
		end)
		actions.OnActionStarted:Connect(function()
			if method == "Spend" then
				mutationSucceeded, mutationReason = resources:Spend("Mana", 10)
			elseif method == "Restore" then
				mutationSucceeded, mutationReason = resources:Restore("Mana", 10)
			elseif method == "Drain" then
				mutationSucceeded, mutationReason = resources:Drain("Mana", 10)
			else
				mutationSucceeded, mutationReason = resources:SetCurrent("Mana", 70)
			end
			beforeReturn = table.clone(changes)
		end)
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		expect(mutationSucceeded).toBe(true)
		expect(mutationReason).toBeNil()
		local expectedCurrent: number = if method == "Restore" then 90 else 70
		expect(beforeReturn).toEqual({ { 100, 80 }, { 80, expectedCurrent } })
		expect(changes).toEqual(beforeReturn)
		expect(resources:GetCurrent("Mana")).toBe(expectedCurrent)
	end)
end

it("issues every Resource transition once under recursive mutation and keeps historical payloads", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20 } },
	}, { mana })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local order: { string } = {}
	local historical: { { number? } } = {}
	local results: { boolean } = {}
	local reasons: { string? } = {}
	local mutationCount: number = 0
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(order, `{change.currentOldValue}->{change.currentNewValue}`)
		-- Bound recursive test work even if a broken journal issues an older transition twice.
		if change.currentNewValue > 60 and mutationCount < 2 then
			mutationCount += 1
			local succeeded: boolean, reason: string? = resources:Spend("Mana", 10)
			table.insert(results, succeeded)
			table.insert(reasons, reason)
			table.insert(historical, { change.currentNewValue, resources:GetCurrent("Mana") })
			table.insert(order, `returned {change.currentNewValue}`)
		end
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(order).toEqual({ "100->80", "80->70", "70->60", "returned 70", "returned 80" })
	expect(results).toEqual({ true, true })
	expect(reasons).toEqual({})
	expect(historical).toEqual({ { 70, 60 }, { 80, 60 } })
	expect(resources:GetCurrent("Mana")).toBe(60)
end)

it("drains every older Resource cost before a nested mutation whose Resource id sorts earlier", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20, Chakra = 10 } },
	}, { mana, { id = "Chakra", visibility = "ServerOnly", autoAssign = true, max = { value = 100 } } })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local order: { string } = {}
	local mutationSucceeded: boolean? = nil
	local mutationReason: string? = nil
	local mutationRequested: boolean = false
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(order, `{change.resourceId} {change.currentOldValue}->{change.currentNewValue}`)
		if change.resourceId == "Chakra" and not mutationRequested then
			mutationRequested = true
			mutationSucceeded, mutationReason = resources:Spend("Chakra", 10)
			table.insert(order, "nested returned")
		end
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(mutationSucceeded).toBe(true)
	expect(mutationReason).toBeNil()
	expect(order).toEqual({ "Chakra 100->90", "Mana 100->80", "Chakra 90->80", "nested returned" })
end)

it("issues outer-before-inner costs when a Resource listener synchronously requests another Action", function()
	local order: { string } = {}
	ResourceTestUtils.initialize({
		{
			id = "Outer",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			onStart = function()
				table.insert(order, "outer hook")
			end,
		},
		{
			id = "Inner",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 10 },
			onStart = function()
				table.insert(order, "inner hook")
			end,
		},
	}, { mana })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local nested: ActionTypes.ActionRequestResult? = nil
	local nestedRequested: boolean = false
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		table.insert(order, "Started " .. event.actionId)
	end)
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(order, `{change.currentOldValue}->{change.currentNewValue}`)
		if change.currentNewValue == 80 and not nestedRequested then
			nestedRequested = true
			nested = actions:RequestAction("Inner")
			table.insert(order, "nested returned")
		end
	end)
	expect(actions:RequestAction("Outer")).toEqual({ accepted = true, sequenceId = 1 })
	expect(nested).toEqual({ accepted = true, sequenceId = 2 })
	expect(order).toEqual({
		"Started Outer",
		"100->80",
		"Started Inner",
		"80->70",
		"inner hook",
		"nested returned",
		"outer hook",
	})
	expect(resources:GetCurrent("Mana")).toBe(70)
end)

it("commits cleanup Resource bounds before scoped preemption callbacks and does not refund the owner", function()
	local claimant: ActionTypes.ActionExecutionContext? = nil
	ResourceTestUtils.initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Claimant" },
			activeTags = { "Capacity" },
			costs = { Mana = 20 },
		},
		{
			id = "Claimant",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionTypes.ActionExecutionContext)
				claimant = context
			end,
		},
		{ id = "Probe", visibility = "ServerOnly", autoGrant = true, locks = { "Hands" } },
	}, { mana }, {
		{
			id = "Capacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { add = 50 } },
		},
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController, _properties: PropertyController, tags: TagController =
		ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect(resources:GetCurrent("Mana")).toBe(80)
	expect(actions:RequestAction("Claimant")).toEqual({ accepted = true, sequenceId = 2 })
	local observations: { { number? } } = {}
	local probes: { ActionTypes.ActionRequestResult } = {}
	local function observe(): ()
		table.insert(observations, { resources:GetCurrent("Mana"), resources:GetMax("Mana") })
		table.insert(probes, actions:RequestAction("Probe"))
	end
	actions.OnActionInterrupted:Connect(observe)
	tags.OnTagRemoved:Connect(observe)
	resources.OnResourceChanged:Connect(observe)
	local claim: ActionTypes.LockClaim?, reason: string? = (claimant :: ActionTypes.ActionExecutionContext):ClaimLocks({
		"Hands",
	})
	expect(claim).never.toBeNil()
	expect(reason).toBeNil()
	expect(observations).toEqual({ { 80, 100 }, { 80, 100 }, { 80, 100 } })
	for _, probe: ActionTypes.ActionRequestResult in probes do
		expect(probe).toEqual({ accepted = false, reason = "ActionLockConflict" })
	end
	(claim :: ActionTypes.LockClaim):Release()
	expect(actions:RequestAction("Probe")).toEqual({ accepted = true, sequenceId = 3 })
end)

it("discards pending Resource notifications when Started destroys the ResourceController", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20 } },
	}, { mana })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local changes: number = 0
	resources.OnResourceChanged:Connect(function()
		changes += 1
	end)
	actions.OnActionStarted:Connect(function()
		resources:Destroy()
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(changes).toBe(0)
	expect(function()
		resources.OnResourceChanged:Connect(function() end)
	end).toThrow()
	expect((actions:EndAction(1))).toBe(true)
end)

it("allows destruction during Resource dispatch without duplicate or later invalid notifications", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Mana = 20, Chakra = 10 } },
	}, { mana, { id = "Chakra", visibility = "ServerOnly", autoAssign = true, max = { value = 100 } } })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local changes: { string } = {}
	local returned: boolean = false
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change.resourceId)
		resources:Destroy()
		resources:Destroy()
		returned = true
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(returned).toBe(true)
	expect(changes).toEqual({ "Chakra" })
	expect(resources:GetCurrent("Mana")).toBeNil()
	expect(function()
		resources.OnResourceChanged:Connect(function() end)
	end).toThrow()
end)

it("updates Property-backed Resource state before base, resolved and umbrella Property listeners", function()
	ResourceTestUtils.initialize({}, { mana })
	local _actor: Actor, _actions: ActionController, resources: ResourceController, properties: PropertyController =
		ResourceTestUtils.registerActor()
	local observations: { { number? } } = {}
	local function observe(): ()
		table.insert(
			observations,
			{ properties:GetResolvedProperty("MaxMana"), resources:GetMax("Mana"), resources:GetCurrent("Mana") }
		)
	end
	properties.OnBasePropertyChanged:Connect(observe)
	properties.OnResolvedPropertyChanged:Connect(observe)
	properties.OnPropertyChanged:Connect(observe)
	expect((properties:SetBaseProperty("MaxMana", 50))).toBe(true)
	expect(observations).toEqual({ { 50, 50, 50 }, { 50, 50, 50 }, { 50, 50, 50 } })
end)

it("commits the final Property-backed regeneration rate before Started can step the Resource", function()
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			activeTags = { "Regen" },
		},
	}, {
		{
			id = "Mana",
			visibility = "ServerOnly",
			autoAssign = true,
			max = { value = 100 },
			regen = { rate = { propertyName = "ManaRegen", defaultBaseValue = 2 } },
		},
	}, {
		{
			id = "Regen",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { ManaRegen = { set = 5 } },
		},
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local transitions: { { number } } = {}
	local afterStep: number? = nil
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(transitions, { change.currentOldValue, change.currentNewValue })
	end)
	actions.OnActionStarted:Connect(function()
		resources:Step(1)
		afterStep = resources:GetCurrent("Mana")
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(afterStep).toBe(85)
	expect(transitions).toEqual({ { 100, 80 }, { 80, 85 } })
end)

it("keeps Resource getters as cached reads in a lifecycle callback", function()
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			activeTags = { "Capacity" },
		},
	}, { mana }, {
		{
			id = "Capacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { set = 90 } },
		},
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController, properties: PropertyController =
		ResourceTestUtils.registerActor()
	local originalGetter = properties.GetResolvedProperty
	local queryReads: number = 0
	local observed: { { number? } } = {}
	actions.OnActionStarted:Connect(function()
		properties.GetResolvedProperty = function(self: PropertyController, name: string): number?
			queryReads += 1
			return originalGetter(self, name)
		end
		for _index: number = 1, 3 do
			table.insert(observed, { resources:GetCurrent("Mana"), resources:GetMin("Mana"), resources:GetMax("Mana") })
		end
		properties.GetResolvedProperty = originalGetter
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(observed).toEqual({ { 80, 0, 90 }, { 80, 0, 90 }, { 80, 0, 90 } })
	expect(queryReads).toBe(0)
end)

it("keeps pending activation and destruction Resource transitions ordered when Started destroys Actions", function()
	local startedHook: number = 0
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			activeTags = { "Capacity" },
			onStart = function()
				startedHook += 1
			end,
		},
	}, { mana }, {
		{
			id = "Capacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { add = 50 } },
		},
	})
	local actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	local changes: { ResourceChange } = {}
	local interruptedState: { number? } = {}
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)
	actions.OnActionInterrupted:Connect(function()
		interruptedState = { resources:GetCurrent("Mana"), resources:GetMax("Mana") }
	end)
	actions.OnActionStarted:Connect(function()
		actions:Destroy()
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(startedHook).toBe(0)
	expect(interruptedState).toEqual({ 80, 100 })
	expect(changes).toEqual({
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 100,
			currentNewValue = 80,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 100,
			maxNewValue = 150,
		},
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 80,
			currentNewValue = 80,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 150,
			maxNewValue = 100,
		},
	})
	expect(actions:RequestAction("Cast")).toEqual({ accepted = false, reason = "ActionControllerDestroyed" })
end)

it("preserves both prepared spends when Started synchronously preempts its own Action", function()
	local hooks: { string } = {}
	ResourceTestUtils.initialize({
		{
			id = "Outer",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Inner" },
			costs = { Mana = 20 },
			activeTags = { "OuterCapacity" },
			onStart = function()
				table.insert(hooks, "outer start")
			end,
			onInterrupt = function()
				table.insert(hooks, "outer interrupt")
			end,
		},
		{
			id = "Inner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			costs = { Mana = 10 },
			activeTags = { "InnerCapacity" },
			onStart = function()
				table.insert(hooks, "inner start")
			end,
		},
	}, { mana }, {
		{
			id = "OuterCapacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { set = 90 } },
		},
		{
			id = "InnerCapacity",
			visibility = "ServerOnly",
			duplicateBehavior = "Stack",
			properties = { MaxMana = { set = 60 } },
		},
	})
	local actor: Actor, actions: ActionController, resources: ResourceController, _properties: PropertyController, tags: TagController =
		ResourceTestUtils.registerActor()
	local changes: { ResourceChange } = {}
	local observations: { boolean } = {}
	local nested: ActionTypes.ActionRequestResult? = nil
	local lifecycle: { string } = {}
	resources.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
		local innerCommitted: boolean = resources:GetCurrent("Mana") == 60
			and resources:GetMax("Mana") == 60
			and not tags:HasTag("OuterCapacity")
			and tags:HasTag("InnerCapacity")
		local outerCommitted: boolean = resources:GetCurrent("Mana") == 80
			and resources:GetMax("Mana") == 90
			and tags:HasTag("OuterCapacity")
			and not tags:HasTag("InnerCapacity")
		-- Older notifications may drain before or after the nested commit; either query must describe a complete transaction.
		table.insert(observations, innerCommitted or (change.currentNewValue == 80 and outerCommitted))
	end)
	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		table.insert(lifecycle, "Interrupted " .. event.actionId)
	end)
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		table.insert(lifecycle, "Started " .. event.actionId)
		if event.actionId == "Outer" then
			nested = actions:RequestAction("Inner")
			table.insert(hooks, "nested returned")
		end
	end)
	expect(actions:RequestAction("Outer")).toEqual({ accepted = true, sequenceId = 1 })
	expect(nested).toEqual({ accepted = true, sequenceId = 2 })
	expect(lifecycle).toEqual({ "Started Outer", "Interrupted Outer", "Started Inner" })
	expect(hooks).toEqual({ "outer interrupt", "inner start", "nested returned" })
	expect(observations).toEqual({ true, true })
	expect(changes).toEqual({
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 100,
			currentNewValue = 80,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 100,
			maxNewValue = 90,
		},
		{
			actor = actor,
			resourceId = "Mana",
			currentOldValue = 80,
			currentNewValue = 60,
			minOldValue = 0,
			minNewValue = 0,
			maxOldValue = 90,
			maxNewValue = 60,
		},
	})
end)
