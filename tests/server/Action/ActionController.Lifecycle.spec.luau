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

it("creates a frozen execution shell and fresh mutable private state for each instance", function()
	local contexts: { any } = {}
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		table.insert(contexts, context)
	end
	local actor: Actor, controller: any = createController(definition)
	local parameters: { [string]: any } = { value = 7 }
	local first: any = controller:RequestAction("Action.Sprint", parameters)
	local second: any = controller:RequestAction("Action.Sprint", parameters)
	expect(first.accepted).toBe(true)
	expect(second.accepted).toBe(true)
	expect(#contexts).toBe(2)
	expect(contexts[1].actor).toBe(actor)
	expect(contexts[1].actionId).toBe("Action.Sprint")
	expect(contexts[1].sequenceId).toBe(first.sequenceId)
	expect(contexts[1].parameters).toBe(parameters)
	expect(table.isfrozen(contexts[1])).toBe(true)
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
	contexts[1].state.counter = 4
	expect(contexts[1].state.counter).toBe(4)
	expect(contexts[2].state.counter).toBeNil()
	expect(contexts[1].state).never.toBe(contexts[2].state)
	expect(function()
		contexts[1].sequenceId = second.sequenceId
	end).toThrow()
	expect(controller:EndAction(first.sequenceId)).toBe(true)
	expect(contexts[1]:IsActive()).toBe(false)
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("keeps an Action active when onStart returns or is absent", function()
	local definition: ActionDefinition = action()
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result.accepted).toBe(true)
	expect(controller:EndAction(result.sequenceId)).toBe(true)
end)

it("keeps an Action active after its onStart callback returns normally", function()
	local context: any = nil
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result.accepted).toBe(true)
	expect(context:IsActive()).toBe(true)
	expect(controller:EndAction(result.sequenceId)).toBe(true)
end)

it("issues Started before onStart and preserves acceptance after synchronous self-End", function()
	local observed: { string } = {}
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any)
		table.insert(observed, "start")
		expect(context:End()).toBe(true)
	end
	local actor: Actor, controller: any = createController(definition)
	local startedEvent: any = nil
	local endedEvent: any = nil
	controller.OnActionStarted:Connect(function(event: any)
		startedEvent = event
	end)
	controller.OnActionEnded:Connect(function(event: any)
		endedEvent = event
	end)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result).toEqual({ accepted = true, sequenceId = 1 })
	expect(observed).toEqual({ "start" })
	flushEvents()
	expect(startedEvent).toEqual({ actor = actor, actionId = "Action.Sprint", sequenceId = 1 })
	expect(endedEvent).toEqual({ actor = actor, actionId = "Action.Sprint", sequenceId = 1 })
	expect(controller:EndAction(1)).toBe(false)
end)

it("commits End before onEnd and emits one Ended event without Interrupt", function()
	local context: any = nil
	local hookContext: any = nil
	local hookActive: boolean? = nil
	local repeatEnd: boolean? = nil
	local endCount: number = 0
	local endedCount: number = 0
	local interruptedCount: number = 0
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
	end
	definition.onEnd = function(value: any)
		endCount += 1
		hookContext = value
		hookActive = value:IsActive()
		repeatEnd = value:End()
	end
	definition.onInterrupt = function()
		interruptedCount += 1
	end
	local _actor: Actor, controller: any = createController(definition)
	controller.OnActionEnded:Connect(function()
		endedCount += 1
	end)
	controller.OnActionInterrupted:Connect(function()
		interruptedCount += 1
	end)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(controller:EndAction(result.sequenceId)).toBe(true)
	expect(context:IsActive()).toBe(false)
	expect(controller:EndAction(result.sequenceId)).toBe(false)
	expect(controller:InterruptAction(result.sequenceId, "Late")).toBe(false)
	flushEvents()
	expect(endCount).toBe(1)
	expect(hookContext).toBe(context)
	expect(hookActive).toBe(false)
	expect(repeatEnd).toBe(false)
	expect(endedCount).toBe(1)
	expect(interruptedCount).toBe(0)
end)

it("commits Interrupt before onInterrupt and preserves its reason in event and hook", function()
	local context: any = nil
	local hookContext: any = nil
	local hookActive: boolean? = nil
	local hookReason: string? = nil
	local event: any = nil
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
	end
	definition.onInterrupt = function(value: any, reason: string)
		hookContext = value
		hookActive = value:IsActive()
		hookReason = reason
	end
	local actor: Actor, controller: any = createController(definition)
	controller.OnActionInterrupted:Connect(function(value: any)
		event = value
	end)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(controller:InterruptAction(result.sequenceId, "GameCancelled")).toBe(true)
	flushEvents()
	expect(hookContext).toBe(context)
	expect(hookActive).toBe(false)
	expect(hookReason).toBe("GameCancelled")
	expect(event).toEqual({ actor = actor, actionId = "Action.Sprint", sequenceId = 1, reason = "GameCancelled" })
	expect(controller:InterruptAction(result.sequenceId, "Again")).toBe(false)
	expect(controller:EndAction(result.sequenceId)).toBe(false)
end)

it("rejects invalid sequence ids and interruption reasons without terminating the instance", function()
	local definition: ActionDefinition = action()
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	for _, sequenceId: any in { 0, -1, 1.5, "1", {} } :: { any } do
		local ended: boolean, endReason: string? = controller:EndAction(sequenceId)
		local stopped: boolean, stopReason: string? = controller:RequestStop(sequenceId)
		expect(ended).toBe(false)
		expect(type(endReason)).toBe("string")
		expect(stopped).toBe(false)
		expect(type(stopReason)).toBe("string")
	end
	for _, reason: any in { "", 12, {} } :: { any } do
		local interrupted: boolean, failureReason: string? = controller:InterruptAction(result.sequenceId, reason)
		expect(interrupted).toBe(false)
		expect(type(failureReason)).toBe("string")
	end
	expect(controller:EndAction(result.sequenceId)).toBe(true)
end)

it("self-Interrupt from onStart remains an accepted request with one terminal transition", function()
	local context: any = nil
	local selfInterrupted: boolean? = nil
	local afterInterrupt: boolean = false
	local hookCount: number = 0
	local definition: ActionDefinition = action()
	definition.onStart = function(value: any)
		context = value
		selfInterrupted = value:Interrupt("GameCancelled")
		afterInterrupt = true
	end
	definition.onInterrupt = function()
		hookCount += 1
	end
	local _actor: Actor, controller: any = createController(definition)
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	expect(afterInterrupt).toBe(true)
	expect(selfInterrupted).toBe(true)
	expect(context:IsActive()).toBe(false)
	expect(hookCount).toBe(1)
	expect(context:Interrupt("Again")).toBe(false)
end)

it("interrupts an active Action once when onStart errors", function()
	local interruptedCount: number = 0
	local interruptedReason: string? = nil
	local hookActive: boolean? = nil
	local definition: ActionDefinition = action()
	definition.onStart = function(): ()
		error("start boom")
	end
	definition.onInterrupt = function(context: any, reason: string)
		hookActive = context:IsActive()
		interruptedCount += 1
		interruptedReason = reason
	end
	local _actor: Actor, controller: any = createController(definition)
	local result: any = controller:RequestAction("Action.Sprint")
	expect(result).toEqual({ accepted = true, sequenceId = 1 })
	expect(interruptedCount).toBe(1)
	expect(hookActive).toBe(false)
	expect(type(interruptedReason)).toBe("string")
	expect(interruptedReason).never.toBe("")
	expect(controller:EndAction(result.sequenceId)).toBe(false)
end)

it("does not make a second terminal transition when onStart errors after self-End", function()
	local endedCount: number = 0
	local interruptedCount: number = 0
	local definition: ActionDefinition = action()
	definition.onStart = function(context: any): ()
		context:End()
		error("late start boom")
	end
	local _actor: Actor, controller: any = createController(definition)
	controller.OnActionEnded:Connect(function()
		endedCount += 1
	end)
	controller.OnActionInterrupted:Connect(function()
		interruptedCount += 1
	end)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	flushEvents()
	expect(endedCount).toBe(1)
	expect(interruptedCount).toBe(0)
end)

it("keeps committed End or Interrupt after a terminal callback errors", function()
	for _, terminal: string in { "End", "Interrupt" } do
		local definition: ActionDefinition = action()
		definition.onEnd = function(): ()
			error("end boom")
		end
		definition.onInterrupt = function(): ()
			error("interrupt boom")
		end
		local _actor: Actor, controller: any = createController(definition)
		local result: any = controller:RequestAction("Action.Sprint")
		if terminal == "End" then
			expect(controller:EndAction(result.sequenceId)).toBe(true)
		else
			expect(controller:InterruptAction(result.sequenceId, "Manual")).toBe(true)
		end
		expect(controller:EndAction(result.sequenceId)).toBe(false)
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("contains a yielding terminal hook without keeping its Action active", function()
	for _, terminal: string in { "End", "Interrupt" } do
		local continued: boolean = false
		local definition: ActionDefinition = action()
		local callback = function(): ()
			task.wait()
			continued = true
		end
		if terminal == "End" then
			definition.onEnd = callback
		else
			definition.onInterrupt = callback
		end
		local _actor: Actor, controller: any = createController(definition)
		local result: any = controller:RequestAction("Action.Sprint")
		if terminal == "End" then
			expect(controller:EndAction(result.sequenceId)).toBe(true)
		else
			expect(controller:InterruptAction(result.sequenceId, "Manual")).toBe(true)
		end
		expect(controller:EndAction(result.sequenceId)).toBe(false)
		flushEvents()
		expect(continued).toBe(false)
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)
