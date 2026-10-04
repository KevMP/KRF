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
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionFactory = ActionTypes.ActionFactory
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type ActionInterruptionContext = ActionTypes.ActionInterruptionContext
type LockClaim = ActionTypes.LockClaim
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor

local controllers: { ActionController } = {}

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
end)

afterEach(function()
	for _, controller: ActionController in controllers do
		controller:Destroy()
	end
	ActionRegistry._resetForTests()
end)

local function loadDefinitions(definitions: { ActionDefinition }): ()
	local factories: { ActionFactory } = {}
	for _, definition: ActionDefinition in definitions do
		local source: ActionDefinition = definition
		table.insert(factories, function(): ActionDefinition
			return table.clone(source)
		end)
	end
	local loaded: boolean, reason: string? = ActionRegistry.Load(factories, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end

local function createController(): (Actor, ActionController)
	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: ActionController = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	return actor, controller
end

it("uses the captured callback and the same lexical state as an instance's start hook", function()
	local calls: { string } = {}
	local factoryCalls: number = 0
	local ownerFactory: ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		local state: string = if factoryCalls == 1 then "catalog" else "created"
		return {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(_context: ActionExecutionContext): ()
				state = "started"
			end,
			canBeInterruptedBy = function(
				_context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(calls, state)
				return state == "started"
			end,
		}
	end
	local dodgeFactory: ActionFactory = function(): ActionDefinition
		return { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } }
	end
	expect((ActionRegistry.Load({ ownerFactory, dodgeFactory }, {}, {}))).toBe(true)
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Dodge").accepted).toBe(true)
	expect(calls).toEqual({ "started" })
end)

it("keeps separate interruption decisions for concurrent instances of the same Action", function()
	local contexts: { ActionExecutionContext } = {}
	local decisions: { string } = {}
	local factoryCalls: number = 0
	local ownerFactory: ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		local allow: boolean = factoryCalls == 2
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext): ()
				table.insert(contexts, context)
			end,
			canBeInterruptedBy = function(
				context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(decisions, tostring(context.sequenceId) .. ":" .. tostring(allow))
				return allow
			end,
		}
	end
	local dodgeFactory: ActionFactory = function(): ActionDefinition
		return { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement", "Combat" } }
	end
	expect((ActionRegistry.Load({ ownerFactory, dodgeFactory }, {}, {}))).toBe(true)
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	local firstClaim: LockClaim?, firstReason: string? = contexts[1]:ClaimLocks({ "Movement" })
	local secondClaim: LockClaim?, secondReason: string? = contexts[2]:ClaimLocks({ "Combat" })
	expect(firstReason).toBeNil()
	expect(secondReason).toBeNil()
	expect(firstClaim).never.toBeNil()
	expect(secondClaim).never.toBeNil()
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(decisions).toEqual({ "1:true", "2:false" })
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
end)

it("does not replace a running instance's captured hook when its factory table is mutated", function()
	local latestDefinition: ActionDefinition? = nil
	local calls: { string } = {}
	local ownerFactory: ActionFactory = function(): ActionDefinition
		local definition: ActionDefinition = {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				_context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(calls, "captured")
				return true
			end,
		}
		latestDefinition = definition
		return definition
	end
	local dodgeFactory: ActionFactory = function(): ActionDefinition
		return { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } }
	end
	expect((ActionRegistry.Load({ ownerFactory, dodgeFactory }, {}, {}))).toBe(true)
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	local capturedDefinition: ActionDefinition = latestDefinition :: ActionDefinition
	capturedDefinition.canBeInterruptedBy = function(): boolean
		table.insert(calls, "mutated")
		return false
	end
	expect(controller:RequestAction("Action.Dodge").accepted).toBe(true)
	expect(calls).toEqual({ "captured" })
end)

it("denies preemption after a decision hook errors without mutating its owner", function()
	local ownerContext: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext): ()
				ownerContext = context
			end,
			canBeInterruptedBy = function(): boolean
				error("decision boom")
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	expect(controller:RequestAction("Action.Dodge")).toEqual({
		accepted = false,
		reason = "ActionInterruptDecisionFailed",
	})
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
end)

it("denies preemption after a decision hook yields and never resumes it", function()
	local resumed: boolean = false
	local ownerContext: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext): ()
				ownerContext = context
			end,
			canBeInterruptedBy = function(): boolean
				task.wait()
				resumed = true
				return true
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	expect(controller:RequestAction("Action.Dodge")).toEqual({
		accepted = false,
		reason = "ActionInterruptDecisionYielded",
	})
	task.wait()
	expect(resumed).toBe(false)
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
end)

it("denies a non-boolean interruption decision without mutating its owner", function()
	local ownerContext: ActionExecutionContext? = nil
	local invalidCallback: any = function(): string
		return "yes"
	end
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext): ()
				ownerContext = context
			end,
			canBeInterruptedBy = invalidCallback,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	expect(controller:RequestAction("Action.Dodge")).toEqual({
		accepted = false,
		reason = "ActionInterruptDecisionInvalidResult",
	})
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
end)

it("does not consult lock preemption permissions for an explicit manual Interrupt", function()
	local reasonSeen: string? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				reasonSeen = reason
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	expect((controller:InterruptAction(owner.sequenceId, "GameCancelled"))).toBe(true)
	expect(reasonSeen).toBe("GameCancelled")
	expect(controller:RequestAction("Action.Dodge").accepted).toBe(true)
end)
