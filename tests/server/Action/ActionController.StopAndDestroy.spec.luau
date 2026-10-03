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
type ActionDefinition = ActionTypes.ActionDefinition
type Actor = ActorTypes.Actor

local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

local controllers: { any } = {}

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
end)

afterEach(function()
	for _, controller: any in controllers do
		controller:Destroy()
	end
	ActionRegistry._resetForTests()
end)

local function createController(definition: ActionDefinition): (Actor, any)
	local loaded: boolean, reason: string? = ActionRegistry.Load({
		function(): ActionDefinition
			return table.clone(definition)
		end,
	}, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: any = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	return actor, controller
end

local function action(): ActionDefinition
	return { id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true }
end

local function flushEvents(): ()
	task.wait()
	task.wait()
end

it("uses one factory instance across start, stop, end, and interrupt callbacks", function()
	local observations: { string } = {}
	local created: number = 0
	local factory = function(): ActionDefinition
		created += 1
		local privateCount: number = 0
		return {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function()
				privateCount += 1
			end,
			onStopRequested = function(context, request)
				privateCount += request.parameters
				table.insert(observations, tostring(context.sequenceId) .. ":" .. tostring(privateCount))
			end,
			onEnd = function()
				table.insert(observations, "end:" .. tostring(privateCount))
			end,
			onInterrupt = function()
				table.insert(observations, "interrupt:" .. tostring(privateCount))
			end,
		}
	end
	local loaded: boolean = ActionRegistry.Load({ factory }, {}, {})
	expect(loaded).toBe(true)
	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: any = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	local first: any = controller:RequestAction("Action.Sprint")
	local second: any = controller:RequestAction("Action.Sprint")
	expect(created).toBe(3)
	expect((controller:RequestStop(first.sequenceId, 2))).toBe(true)
	expect((controller:RequestStop(first.sequenceId, 3))).toBe(true)
	expect((controller:RequestStop(second.sequenceId, 4))).toBe(true)
	expect(observations).toEqual({ "1:3", "1:6", "2:5" })
	expect((controller:EndAction(first.sequenceId))).toBe(true)
	expect((controller:InterruptAction(second.sequenceId, "Manual"))).toBe(true)
	expect(observations).toEqual({ "1:3", "1:6", "2:5", "end:6", "interrupt:5" })
	expect((controller:RequestStop(first.sequenceId))).toBe(false)
end)

it("delivers stop synchronously without automatic termination", function()
	local context: any = nil
	local requests: { any } = {}
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
	end
	definition.onStopRequested = function(value: any, request: any)
		expect(value).toBe(context)
		table.insert(requests, request.parameters)
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	local parameters = { charge = 7 }
	expect((controller:RequestStop(result.sequenceId, parameters))).toBe(true)
	expect(requests).toEqual({ parameters })
	expect(context:IsActive()).toBe(true)
	expect((controller:RequestStop(result.sequenceId, 3))).toBe(true)
	expect(requests).toEqual({ parameters, 3 })
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("accepts a stop request when the Action has no stop callback", function()
	local _actor: Actor, controller: any = createController(action())
	local result: any = controller:RequestAction("Action.Sprint")
	expect((controller:RequestStop(result.sequenceId))).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("contains yielding and failing stop callbacks without ending the Action", function()
	for _, failure: string in { "error", "yield" } do
		local continued: boolean = false
		local definition: ActionDefinition = action()
		definition.onStopRequested = function()
			if failure == "error" then
				error("stop boom")
			end
			task.wait()
			continued = true
		end
		local _actor: Actor, controller: any = createController(definition)
		local result: any = controller:RequestAction("Action.Sprint")
		expect((controller:RequestStop(result.sequenceId))).toBe(true)
		expect((controller:EndAction(result.sequenceId))).toBe(true)
		flushEvents()
		expect(continued).toBe(false)
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("retires a suspended onStart on external End, Interrupt, and Destroy", function()
	for _, termination: string in { "End", "Interrupt", "Destroy" } do
		local resumed: boolean = false
		local context: any = nil
		local definition: ActionDefinition = action()
		definition.onStart = function(value: any)
			context = value
			task.wait()
			resumed = true
		end
		local _actor: Actor, controller: any = createController(definition)
		local result: any = controller:RequestAction("Action.Sprint")
		if termination == "End" then
			expect((controller:EndAction(result.sequenceId))).toBe(true)
		elseif termination == "Interrupt" then
			expect((controller:InterruptAction(result.sequenceId, "Manual"))).toBe(true)
		else
			controller:Destroy()
		end
		expect(context:IsActive()).toBe(false)
		flushEvents()
		expect(resumed).toBe(false)
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("retires an onStart invocation that suspends after self-termination", function()
	local context: any = nil
	local selfEnded: boolean? = nil
	local continued: boolean = false
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
		selfEnded = value:End()
		task.wait()
		continued = true
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result.accepted).toBe(true)
	expect(selfEnded).toBe(true)
	expect(context:IsActive()).toBe(false)
	flushEvents()
	expect(continued).toBe(false)
end)

it("commits all active instances inactive before the first teardown hook", function()
	local contexts: { any } = {}
	local interruptedReasons: { string } = {}
	local observedAllInactive: { boolean } = {}
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		table.insert(contexts, context)
	end
	definition.onInterrupt = function(_context: any, reason: string)
		local allInactive: boolean = true
		for _, context: any in contexts do
			allInactive = allInactive and not context:IsActive()
		end
		table.insert(observedAllInactive, allInactive)
		table.insert(interruptedReasons, reason)
	end
	local _actor: Actor, controller: any = createController(definition)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	controller:Destroy()
	expect(observedAllInactive).toEqual({ true, true })
	expect(#interruptedReasons).toBe(2)
	expect(interruptedReasons[1]).toBe("ActionControllerDestroyed")
	expect(interruptedReasons[2]).toBe(interruptedReasons[1])
	controller:Destroy()
	expect(#interruptedReasons).toBe(2)
end)

it("contains a failing teardown hook and still interrupts every instance", function()
	local calls: number = 0
	local definition: ActionDefinition = action()
	definition.onInterrupt = function(): ()
		calls += 1
		error("cleanup boom")
	end
	local _actor: Actor, controller: any = createController(definition)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	controller:Destroy()
	expect(calls).toBe(2)
end)

it("rejects public mutations during teardown and emits one interruption per active instance", function()
	local controller: any = nil
	local contexts: { any } = {}
	local mutationResults: { boolean } = {}
	local interruptionCount: number = 0
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		table.insert(contexts, context)
	end
	definition.onInterrupt = function(context: any)
		local requested: any = controller:RequestAction("Action.Sprint")
		table.insert(mutationResults, requested.accepted)
		table.insert(mutationResults, (controller:RequestStop(context.sequenceId)))
		table.insert(mutationResults, (controller:EndAction(context.sequenceId)))
		table.insert(mutationResults, (controller:InterruptAction(context.sequenceId, "Again")))
	end
	local _actor: Actor
	_actor, controller = createController(definition)
	controller.OnActionInterrupted:Connect(function()
		interruptionCount += 1
	end)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	controller:Destroy()
	expect(mutationResults).toEqual({ false, false, false, false, false, false, false, false })
	expect(contexts[1]:IsActive()).toBe(false)
	expect(contexts[2]:IsActive()).toBe(false)
	flushEvents()
	expect(interruptionCount).toBe(2)
end)
