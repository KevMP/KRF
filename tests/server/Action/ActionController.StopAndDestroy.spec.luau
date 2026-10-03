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
	local loaded: boolean, reason: string? = ActionRegistry.Load({ definition }, {}, {})
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

it("delivers opaque stop parameters to a waiter armed before RequestAction returns", function()
	local context: any = nil
	local received: any = nil
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
		received = value.OnStopRequested:Wait()
		value:End()
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result.accepted).toBe(true)
	expect(context:IsActive()).toBe(true)
	local parameters: { [string]: number } = { charge = 7 }
	expect((controller:RequestStop(result.sequenceId, parameters))).toBe(true)
	flushEvents()
	expect(received.parameters).toBe(parameters)
	expect(context:IsActive()).toBe(false)
end)

it("notifies only the targeted instance and never ends an Action by default", function()
	local contexts: { any } = {}
	local counts: { number } = { 0, 0 }
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		table.insert(contexts, context)
	end
	local _actor: Actor, controller: any = createController(definition)
	local first: any = controller:RequestAction("Action.Sprint")
	local second: any = controller:RequestAction("Action.Sprint")
	expect(contexts[1].OnStopRequested).never.toBe(contexts[2].OnStopRequested)
	contexts[1].OnStopRequested:Connect(function()
		counts[1] += 1
	end)
	contexts[2].OnStopRequested:Connect(function()
		counts[2] += 1
	end)
	expect((controller:RequestStop(first.sequenceId))).toBe(true)
	expect((controller:RequestStop(first.sequenceId))).toBe(true)
	flushEvents()
	expect(counts).toEqual({ 2, 0 })
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
	expect((controller:RequestStop(second.sequenceId))).toBe(true)
	flushEvents()
	expect(counts).toEqual({ 2, 1 })
end)

it("offers normal Connect and Once semantics on the read-only stop Event", function()
	local context: any = nil
	local connected: number = 0
	local once: number = 0
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(function()
		local _: any = context.OnStopRequested.Fire
	end).toThrow()
	context.OnStopRequested:Connect(function()
		connected += 1
	end)
	context.OnStopRequested:Once(function()
		once += 1
	end)
	expect((controller:RequestStop(result.sequenceId))).toBe(true)
	expect((controller:RequestStop(result.sequenceId))).toBe(true)
	flushEvents()
	expect(connected).toBe(2)
	expect(once).toBe(1)
end)

it("one stop Wait consumes only the first of back-to-back stop requests", function()
	local received: { number } = {}
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		local first: any = context.OnStopRequested:Wait()
		table.insert(received, first.parameters)
		local second: any = context.OnStopRequested:Wait()
		table.insert(received, second.parameters)
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect((controller:RequestStop(result.sequenceId, 1))).toBe(true)
	expect((controller:RequestStop(result.sequenceId, 2))).toBe(true)
	flushEvents()
	expect(received).toEqual({ 1 })
	expect((controller:RequestStop(result.sequenceId, 3))).toBe(true)
	flushEvents()
	expect(received).toEqual({ 1, 3 })
end)

it("retires a suspended onStart on external End, Interrupt, and Destroy", function()
	for _, termination: string in { "End", "Interrupt", "Destroy" } do
		local resumed: boolean = false
		local context: any = nil
		local definition: ActionDefinition = action()
		definition.onStart = function(value: any)
			context = value
			value.OnStopRequested:Wait()
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
		expect(function()
			context.OnStopRequested:Connect(function() end)
		end).toThrow()
		flushEvents()
		expect(resumed).toBe(false)
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("does not run a queued stop continuation after external termination", function()
	local resumed: boolean = false
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		context.OnStopRequested:Wait()
		resumed = true
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect((controller:RequestStop(result.sequenceId))).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
	flushEvents()
	expect(resumed).toBe(false)
end)

it("interrupts once when a stop-resumed onStart errors while still active", function()
	local interruptedCount: number = 0
	local interruptedReason: string? = nil
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any): ()
		context.OnStopRequested:Wait()
		error("resumed start boom")
	end
	definition.onInterrupt = function(_context: any, reason: string)
		interruptedCount += 1
		interruptedReason = reason
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect((controller:RequestStop(result.sequenceId))).toBe(true)
	flushEvents()
	expect(interruptedCount).toBe(1)
	expect(type(interruptedReason)).toBe("string")
	expect(interruptedReason).never.toBe("")
	expect((controller:EndAction(result.sequenceId))).toBe(false)
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
