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
local ActionControllerUpdates = require(KRF.server.Action.utils.ActionControllerUpdates)
local ResourceTestUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type ActionDefinition = ActionTypes.ActionDefinition
type ResourceController = ResourceTypes.ResourceController
beforeEach(ResourceTestUtils.reset)
afterEach(ResourceTestUtils.cleanup)

local mana: ResourceTypes.ResourceDefinition = {
	id = "Mana",
	visibility = "ServerOnly",
	autoAssign = true,
	max = { value = 100 },
}

for _, terminal: string in { "End", "Interrupt", "preemption", "stop", "onStart error", "onUpdate error", "destroy" } do
	it("permanently consumes accepted costs after " .. terminal, function()
		local now: number = 100
		ActionControllerUpdates._setClockForTests(function(): number
			return now
		end)
		local definition: ActionDefinition = {
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Replacement" },
			costs = { Mana = 20 },
		}
		if terminal == "onStart error" then
			definition.onStart = function(_context: ActionTypes.ActionExecutionContext): ()
				error("StartFailure")
			end
		end
		if terminal == "onUpdate error" then
			definition.onUpdate = function(_context: ActionTypes.ActionExecutionContext, _deltaTime: number): ()
				error("UpdateFailure")
			end
		end
		if terminal == "stop" then
			definition.onStopRequested = function(context: ActionTypes.ActionExecutionContext)
				context:End()
			end
		end
		ResourceTestUtils.initialize(
			{ definition, { id = "Replacement", visibility = "ServerOnly", autoGrant = true, locks = { "Hands" } } },
			{ mana }
		)
		local _actor: Actor, actions: ActionController, resources: ResourceController =
			ResourceTestUtils.registerActor()
		expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
		if terminal == "End" then
			expect((actions:EndAction(1))).toBe(true)
		elseif terminal == "Interrupt" then
			expect((actions:InterruptAction(1, "Test"))).toBe(true)
		elseif terminal == "preemption" then
			expect(actions:RequestAction("Replacement")).toEqual({ accepted = true, sequenceId = 2 })
		elseif terminal == "stop" then
			expect((actions:RequestStop(1))).toBe(true)
		elseif terminal == "onUpdate error" then
			now += 0.1
			ActionControllerUpdates._heartbeatForTests(0.1)
		elseif terminal == "destroy" then
			actions:Destroy()
		end
		expect(resources:GetCurrent("Mana")).toBe(80)
		local ended: boolean, reason: string? = actions:EndAction(1)
		expect(ended).toBe(false)
		expect(reason).toBe(if terminal == "destroy" then "ActionControllerDestroyed" else "ActionInstanceNotActive")
	end)
end

it("uses Resource cooldown regeneration and shared charges across independent Actions", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Cooldown = 1, Charges = 1 } },
		{ id = "Other", visibility = "ServerOnly", autoGrant = true, costs = { Cooldown = 1, Charges = 1 } },
	}, {
		{
			id = "Cooldown",
			visibility = "ServerOnly",
			autoAssign = true,
			max = { value = 1 },
			regen = { rate = { value = 0.2 } },
		},
		{ id = "Charges", visibility = "ServerOnly", autoAssign = true, max = { value = 3 } },
	})
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	ResourceTestUtils.expectRejected(actions:RequestAction("Other"))
	expect(resources:GetCurrent("Charges")).toBe(2)
	resources:Step(4)
	ResourceTestUtils.expectRejected(actions:RequestAction("Cast"))
	expect(resources:GetCurrent("Charges")).toBe(2)
	resources:Step(1)
	expect(actions:RequestAction("Other")).toEqual({ accepted = true, sequenceId = 2 })
	resources:Step(5)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 3 })
	resources:Step(5)
	ResourceTestUtils.expectRejected(actions:RequestAction("Other"))
	expect(resources:GetCurrent("Cooldown")).toBe(1)
	expect(resources:GetCurrent("Charges")).toBe(0)
end)

it("allows several uses of shared charges without a separate Action charge runtime", function()
	ResourceTestUtils.initialize({
		{ id = "Cast", visibility = "ServerOnly", autoGrant = true, costs = { Charges = 1 } },
		{ id = "Other", visibility = "ServerOnly", autoGrant = true, costs = { Charges = 1 } },
	}, { { id = "Charges", visibility = "ServerOnly", autoAssign = true, max = { value = 3 } } })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(actions:RequestAction("Other")).toEqual({ accepted = true, sequenceId = 2 })
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 3 })
	local reason: string = ResourceTestUtils.expectRejected(actions:RequestAction("Other"))
	expect(ResourceTestUtils.expectRejected(actions:RequestAction("Other"))).toBe(reason)
	expect(resources:GetCurrent("Charges")).toBe(0)
end)

it("keeps outcome-dependent Resource mutation and explicit refunds available in lifecycle hooks", function()
	local order: { { number } } = {}
	local hookResults: { boolean } = {}
	ResourceTestUtils.initialize({
		{
			id = "Cast",
			visibility = "ServerOnly",
			autoGrant = true,
			costs = { Mana = 20 },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				local resources: ResourceController =
					context.actor:GetController("ResourceController") :: ResourceController
				local spent: boolean, reason: string? = resources:Spend("Mana", 10)
				table.insert(hookResults, spent and reason == nil)
			end,
			onEnd = function(context: ActionTypes.ActionExecutionContext)
				local resources: ResourceController =
					context.actor:GetController("ResourceController") :: ResourceController
				local restored: boolean, reason: string? = resources:Restore("Mana", 5)
				table.insert(hookResults, restored and reason == nil)
			end,
		},
	}, { mana })
	local _actor: Actor, actions: ActionController, resources: ResourceController = ResourceTestUtils.registerActor()
	resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(order, { change.currentOldValue, change.currentNewValue })
	end)
	expect(actions:RequestAction("Cast")).toEqual({ accepted = true, sequenceId = 1 })
	expect(resources:GetCurrent("Mana")).toBe(70)
	expect((actions:EndAction(1))).toBe(true)
	expect(resources:GetCurrent("Mana")).toBe(75)
	expect(hookResults).toEqual({ true, true })
	expect(order).toEqual({ { 100, 80 }, { 80, 70 }, { 70, 75 } })
end)
