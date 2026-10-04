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

it("runs lockless and disjoint-lock Actions concurrently", function()
	loadDefinitions({
		{ id = "Action.Wait", visibility = "ServerOnly", autoGrant = true },
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Aim", visibility = "ServerOnly", autoGrant = true, locks = { "Combat" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local waiting: any = controller:RequestAction("Action.Wait")
	local sprinting: any = controller:RequestAction("Action.Sprint")
	local aiming: any = controller:RequestAction("Action.Aim")
	expect(waiting.accepted).toBe(true)
	expect(sprinting.accepted).toBe(true)
	expect(aiming.accepted).toBe(true)
	expect((controller:EndAction(waiting.sequenceId))).toBe(true)
	expect((controller:EndAction(sprinting.sequenceId))).toBe(true)
	expect((controller:EndAction(aiming.sequenceId))).toBe(true)
end)

it("scopes the same lock id independently to each Actor", function()
	loadDefinitions({
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _firstActor: Actor, firstController: ActionController = createController()
	local _secondActor: Actor, secondController: ActionController = createController()
	expect(firstController:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	expect(secondController:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
end)

it("rejects a conflicting lifetime lock without activating or consuming a sequence id", function()
	loadDefinitions({
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local sprint: any = controller:RequestAction("Action.Sprint")
	expect(sprint).toEqual({ accepted = true, sequenceId = 1 })
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect((controller:EndAction(sprint.sequenceId))).toBe(true)
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = true, sequenceId = 2 })
end)

it("acquires a lifetime lock set all at once and leaves free locks unclaimed on rejection", function()
	loadDefinitions({
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Combat", "Movement" } },
		{ id = "Action.Attack", visibility = "ServerOnly", autoGrant = true, locks = { "Combat" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(controller:RequestAction("Action.Attack")).toEqual({ accepted = true, sequenceId = 2 })
end)

it("uses exact loaded allowlist ids and never grants same-id instances an exception", function()
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local first: any = controller:RequestAction("Action.Sprint")
	expect(first.accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 2 })
	expect((controller:EndAction(first.sequenceId))).toBe(false)
end)

it("allows a same-id instance to preempt when its exact id is explicitly allowlisted", function()
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Sprint" },
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	local first: any = controller:RequestAction("Action.Sprint")
	expect(first.accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 2 })
	expect((controller:EndAction(first.sequenceId))).toBe(false)
end)

it("uses loaded static metadata even if a later factory result changes the allowlist", function()
	local factoryCalls: number = 0
	local factory: ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		return {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = if factoryCalls == 1 then {} else { "Action.Dodge" },
		}
	end
	local dodgeFactory: ActionFactory = function(): ActionDefinition
		return { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } }
	end
	expect((ActionRegistry.Load({ factory, dodgeFactory }, {}, {}))).toBe(true)
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "ActionLockConflict" })
end)

it("releases lifetime locks before End and Interrupt hooks dispatch", function()
	local controller: ActionController? = nil
	local observed: { boolean } = {}
	local replacements: { number } = {}
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onEnd = function(_context: ActionExecutionContext): ()
				local result: any = (controller :: ActionController):RequestAction("Action.Roll")
				table.insert(observed, result.accepted)
				if result.accepted then
					table.insert(replacements, result.sequenceId)
				end
			end,
			onInterrupt = function(_context: ActionExecutionContext, _reason: string): ()
				local result: any = (controller :: ActionController):RequestAction("Action.Roll")
				table.insert(observed, result.accepted)
				if result.accepted then
					table.insert(replacements, result.sequenceId)
				end
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	local first: any = (controller :: ActionController):RequestAction("Action.Sprint")
	expect(((controller :: ActionController):EndAction(first.sequenceId))).toBe(true)
	expect(((controller :: ActionController):EndAction(replacements[1]))).toBe(true)
	local second: any = (controller :: ActionController):RequestAction("Action.Sprint")
	expect(((controller :: ActionController):InterruptAction(second.sequenceId, "Manual"))).toBe(true)
	expect(observed).toEqual({ true, true })
end)

it("has acquired lifetime locks before onStart runs", function()
	local controller: ActionController? = nil
	local competing: any = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onStart = function(_context: ActionExecutionContext): ()
				competing = (controller :: ActionController):RequestAction("Action.Roll")
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect((controller :: ActionController):RequestAction("Action.Sprint").accepted).toBe(true)
	expect(competing).toEqual({ accepted = false, reason = "ActionLockConflict" })
end)

it("passes the owner context and incoming request identity to the captured interruption hook", function()
	local ownerContext: ActionExecutionContext? = nil
	local hookContext: ActionExecutionContext? = nil
	local incoming: ActionInterruptionContext? = nil
	local parameters: { [string]: number } = { direction = 1 }
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
			canBeInterruptedBy = function(context: ActionExecutionContext, value: ActionInterruptionContext): boolean
				hookContext = context
				incoming = value
				return true
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Dodge", parameters).accepted).toBe(true)
	expect(hookContext).toBe(ownerContext)
	expect((incoming :: ActionInterruptionContext).actor).toBe(actor)
	expect((incoming :: ActionInterruptionContext).actionId).toBe("Action.Dodge")
	expect((incoming :: ActionInterruptionContext).parameters).toBe(parameters)
end)

it("lets a captured hook narrow the static allowlist but never expand it", function()
	local calls: number = 0
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				_context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				calls += 1
				return false
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(calls).toBe(0)
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(calls).toBe(1)
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
end)

it("does not execute a startup hook when the active implementation omitted it", function()
	local factoryCalls: number = 0
	local startupCalls: number = 0
	local ownerFactory: ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		return {
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = if factoryCalls == 1
				then function(): boolean
					startupCalls += 1
					return false
				end
				else nil,
		}
	end
	local dodgeFactory: ActionFactory = function(): ActionDefinition
		return { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } }
	end
	expect((ActionRegistry.Load({ ownerFactory, dodgeFactory }, {}, {}))).toBe(true)
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Dodge").accepted).toBe(true)
	expect(startupCalls).toBe(0)
end)

it("evaluates distinct conflicting owners by sequence and interrupts none when one denies", function()
	local decisions: { number } = {}
	local interrupted: { number } = {}
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(decisions, context.sequenceId)
				return true
			end,
			onInterrupt = function(context: ActionExecutionContext, _reason: string): ()
				table.insert(interrupted, context.sequenceId)
			end,
		},
		{
			id = "Action.Aim",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Combat" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(decisions, context.sequenceId)
				return false
			end,
			onInterrupt = function(context: ActionExecutionContext, _reason: string): ()
				table.insert(interrupted, context.sequenceId)
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Combat", "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local sprint: any = controller:RequestAction("Action.Sprint")
	local aim: any = controller:RequestAction("Action.Aim")
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(decisions).toEqual({ 1, 2 })
	expect(interrupted).toEqual({})
	expect((controller:EndAction(sprint.sequenceId))).toBe(true)
	expect((controller:EndAction(aim.sequenceId))).toBe(true)
end)

it("commits every preemption before callbacks and dispatches in sequence order", function()
	local controller: ActionController? = nil
	local contexts: { [string]: ActionExecutionContext } = {}
	local dispatch: { string } = {}
	local reasons: { string } = {}
	local bothRetiredBeforeFirstCallback: boolean? = nil
	local competingDuringFirstCallback: any = nil
	local bothRetiredAtIncomingStart: boolean? = nil
	local competingDuringIncomingStart: any = nil
	local function interrupted(context: ActionExecutionContext, reason: string): ()
		if #dispatch == 0 then
			bothRetiredBeforeFirstCallback = not contexts["Action.Sprint"]:IsActive()
				and not contexts["Action.Aim"]:IsActive()
			competingDuringFirstCallback = (controller :: ActionController):RequestAction("Action.Roll")
		end
		table.insert(dispatch, context.actionId)
		table.insert(reasons, reason)
	end
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext)
				contexts[context.actionId] = context
			end,
			onInterrupt = interrupted,
		},
		{
			id = "Action.Aim",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Combat" },
			interruptibleBy = { "Action.Dodge" },
			onStart = function(context: ActionExecutionContext)
				contexts[context.actionId] = context
			end,
			onInterrupt = interrupted,
		},
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement", "Combat" },
			onStart = function(context: ActionExecutionContext)
				contexts[context.actionId] = context
				bothRetiredAtIncomingStart = not contexts["Action.Sprint"]:IsActive()
					and not contexts["Action.Aim"]:IsActive()
				competingDuringIncomingStart = (controller :: ActionController):RequestAction("Action.Roll")
				table.insert(dispatch, "Action.Dodge")
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect((controller :: ActionController):RequestAction("Action.Sprint").accepted).toBe(true)
	expect((controller :: ActionController):RequestAction("Action.Aim").accepted).toBe(true)
	expect((controller :: ActionController):RequestAction("Action.Dodge").accepted).toBe(true)
	expect(bothRetiredBeforeFirstCallback).toBe(true)
	expect(competingDuringFirstCallback).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(bothRetiredAtIncomingStart).toBe(true)
	expect(competingDuringIncomingStart).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect(dispatch).toEqual({ "Action.Sprint", "Action.Aim", "Action.Dodge" })
	expect(reasons).toEqual({ "ActionLockPreempted", "ActionLockPreempted" })
end)

it("issues every preemption event before an owner hook starts another Action", function()
	local controller: ActionController? = nil
	local events: { string } = {}
	local counterRequest: ActionTypes.ActionRequestResult? = nil
	local counterStartedBeforeReturn: boolean? = nil
	local counterStarted: boolean = false
	local dodgeStarted: boolean = false
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onInterrupt = function(): ()
				counterRequest = (controller :: ActionController):RequestAction("Action.Counter")
				counterStartedBeforeReturn = counterStarted
			end,
		},
		{
			id = "Action.Aim",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Combat" },
			interruptibleBy = { "Action.Dodge" },
		},
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement", "Combat" },
			onStart = function(): ()
				dodgeStarted = true
			end,
		},
		{
			id = "Action.Counter",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(): ()
				counterStarted = true
			end,
		},
	})
	local _actor: Actor
	_actor, controller = createController()
	local activeController: ActionController = controller :: ActionController
	expect(activeController:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	expect(activeController:RequestAction("Action.Aim")).toEqual({ accepted = true, sequenceId = 2 })
	activeController.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent): ()
		table.insert(events, "Interrupted " .. event.actionId)
	end)
	activeController.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent): ()
		table.insert(events, "Started " .. event.actionId)
	end)
	expect(activeController:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 3 })
	expect(counterRequest).toEqual({ accepted = true, sequenceId = 4 })
	expect(counterStartedBeforeReturn).toBe(true)
	expect(dodgeStarted).toBe(true)
	task.wait()
	task.wait()
	expect(events).toEqual({
		"Interrupted Action.Sprint",
		"Interrupted Action.Aim",
		"Started Action.Dodge",
		"Started Action.Counter",
	})
end)

it("emits Started before Interrupted when an interruption hook preempts the incoming Action", function()
	local controller: ActionController? = nil
	local dodgeEvents: { string } = {}
	local counterRequest: ActionTypes.ActionRequestResult? = nil
	local dodgeInterrupted: boolean = false
	local dodgeStarted: boolean = false
	local counterStarted: boolean = false
	local nestedCallbacksRanBeforeReturn: boolean? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onInterrupt = function(): ()
				counterRequest = (controller :: ActionController):RequestAction("Action.Counter")
				nestedCallbacksRanBeforeReturn = dodgeInterrupted and counterStarted
			end,
		},
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Counter" },
			onStart = function(): ()
				dodgeStarted = true
			end,
			onInterrupt = function(): ()
				dodgeInterrupted = true
			end,
		},
		{
			id = "Action.Counter",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onStart = function(): ()
				counterStarted = true
			end,
		},
	})
	local _actor: Actor
	_actor, controller = createController()
	local activeController: ActionController = controller :: ActionController
	activeController.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent): ()
		if event.actionId == "Action.Dodge" then
			table.insert(dodgeEvents, "Started")
		end
	end)
	activeController.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent): ()
		if event.actionId == "Action.Dodge" then
			table.insert(dodgeEvents, "Interrupted")
		end
	end)
	expect((controller :: ActionController):RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	expect((controller :: ActionController):RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 2 })
	expect(counterRequest).toEqual({ accepted = true, sequenceId = 3 })
	expect(nestedCallbacksRanBeforeReturn).toBe(true)
	expect(dodgeStarted).toBe(false)
	task.wait()
	task.wait()
	expect(dodgeEvents).toEqual({ "Started", "Interrupted" })
end)

it("runs a reentrant EndAction hook before returning to an interruption hook", function()
	local controller: ActionController? = nil
	local emoteSequenceId: number? = nil
	local endResult: boolean? = nil
	local endHookRan: boolean = false
	local endHookRanBeforeReturn: boolean? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			onInterrupt = function(): ()
				endResult = (controller :: ActionController):EndAction(emoteSequenceId :: number)
				endHookRanBeforeReturn = endHookRan
			end,
		},
		{
			id = "Action.Emote",
			visibility = "ServerOnly",
			autoGrant = true,
			onEnd = function(): ()
				endHookRan = true
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect((controller :: ActionController):RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	local emoteRequest: ActionTypes.ActionRequestResult = (controller :: ActionController):RequestAction("Action.Emote")
	expect(emoteRequest).toEqual({ accepted = true, sequenceId = 2 })
	emoteSequenceId = (emoteRequest :: ActionTypes.ActionRequestAccepted).sequenceId
	expect((controller :: ActionController):RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 3 })
	expect(endResult).toBe(true)
	expect(endHookRanBeforeReturn).toBe(true)
end)

it("rebuilds the conflict plan after a decision hook ends its own Action", function()
	local controller: ActionController? = nil
	local decisions: { number } = {}
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				table.insert(decisions, context.sequenceId)
				context:End()
				return true
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	local sprint: any = (controller :: ActionController):RequestAction("Action.Sprint")
	expect((controller :: ActionController):RequestAction("Action.Dodge").accepted).toBe(true)
	expect(decisions).toEqual({ sprint.sequenceId })
	expect(((controller :: ActionController):EndAction(sprint.sequenceId))).toBe(false)
end)

it("preempts unchanged lock owners when a decision starts an unrelated lockless Action", function()
	local controller: ActionController? = nil
	local ownerContext: ActionExecutionContext? = nil
	local unrelatedContext: ActionExecutionContext? = nil
	local decisionCalls: number = 0
	local interruptionCalls: number = 0
	local unrelatedRequests: { ActionTypes.ActionRequestResult } = {}
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
				decisionCalls += 1
				table.insert(unrelatedRequests, (controller :: ActionController):RequestAction("Action.Emote"))
				return true
			end,
			onInterrupt = function(): ()
				interruptionCalls += 1
			end,
		},
		{
			id = "Action.Emote",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionExecutionContext): ()
				unrelatedContext = context
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect((controller :: ActionController):RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 1 })
	expect((controller :: ActionController):RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 3 })
	expect(unrelatedRequests).toEqual({ { accepted = true, sequenceId = 2 } })
	expect(decisionCalls).toBe(1)
	expect(interruptionCalls).toBe(1)
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(false)
	expect((unrelatedContext :: ActionExecutionContext):IsActive()).toBe(true)
end)

it("does not commit a stale plan when a decision hook starts a new conflicting owner", function()
	local controller: ActionController? = nil
	local nested: any = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Dodge" },
			canBeInterruptedBy = function(
				context: ActionExecutionContext,
				_incoming: ActionInterruptionContext
			): boolean
				context:End()
				nested = (controller :: ActionController):RequestAction("Action.Roll")
				return true
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect((controller :: ActionController):RequestAction("Action.Sprint").accepted).toBe(true)
	expect((controller :: ActionController):RequestAction("Action.Dodge")).toEqual({
		accepted = false,
		reason = "ActionLockConflict",
	})
	expect(nested).toEqual({ accepted = true, sequenceId = 2 })
	expect(((controller :: ActionController):EndAction(nested.sequenceId))).toBe(true)
end)

it("rechecks an incoming grant revoked by an interruption decision hook", function()
	local controller: ActionController? = nil
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
				(controller :: ActionController):SetGrants("Learned", {})
				return true
			end,
		},
		{ id = "Action.Dodge", visibility = "ServerOnly", locks = { "Movement" } },
	})
	local _actor: Actor
	_actor, controller = createController()
	expect(((controller :: ActionController):SetGrants("Learned", { "Action.Dodge" }))).toBe(true)
	expect((controller :: ActionController):RequestAction("Action.Sprint").accepted).toBe(true)
	expect((controller :: ActionController):RequestAction("Action.Dodge")).toEqual({
		accepted = false,
		reason = "ActionNotGranted",
	})
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
end)
