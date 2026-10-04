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
local ActionControllerUpdates = require(KRF.server.Action.utils.ActionControllerUpdates)
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
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(false)
end)

afterEach(function()
	for _, controller: ActionController in controllers do
		controller:Destroy()
	end
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(true)
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

it("acquires a free scoped lock without creating another ActionInstance", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Channel")
	local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	expect((context :: ActionExecutionContext):IsActive()).toBe(true)
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	local acquiredClaim: LockClaim = claim :: LockClaim
	acquiredClaim:Release()
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = true, sequenceId = 2 })
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
end)

it("rejects a multi-lock scoped claim as a whole and keeps its owner active", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		{ id = "Action.Attack", visibility = "ServerOnly", autoGrant = true, locks = { "Combat" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Combat", "Movement" })
	expect(claim).toBeNil()
	expect(reason).toBe("ActionLockClaimDenied")
	expect((context :: ActionExecutionContext):IsActive()).toBe(true)
	expect(controller:RequestAction("Action.Attack").accepted).toBe(true)
end)

it("validates malformed scoped lock ids without changing the active Action", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	for _, lockIds: any in { false, "Movement", { "" }, { 12 }, { "Movement", "Movement" }, { [2] = "Movement" } } do
		local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks(lockIds)
		expect(claim).toBeNil()
		expect(reason).toBe("ActionLockRequestInvalid")
	end
	expect((context :: ActionExecutionContext):IsActive()).toBe(true)
end)

it("rejects claims from an inactive Action without reacquiring locks", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Channel")
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
	local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(claim).toBeNil()
	expect(reason).toBe("ActionInstanceNotActive")
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
end)

it("preempts a conflicting lifetime owner using the claiming Action identity and parameters", function()
	local claimantContext: ActionExecutionContext? = nil
	local incoming: ActionInterruptionContext? = nil
	local interruptedReason: string? = nil
	local parameters: { [string]: number } = { speed = 2 }
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				claimantContext = value
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Channel" },
			canBeInterruptedBy = function(_context: ActionExecutionContext, value: ActionInterruptionContext): boolean
				incoming = value
				return true
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				interruptedReason = reason
			end,
		},
	})
	local actor: Actor, controller: ActionController = createController()
	local claimant: any = controller:RequestAction("Action.Channel", parameters)
	local owner: any = controller:RequestAction("Action.Sprint")
	local claim: LockClaim?, reason: string? = (claimantContext :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	expect((incoming :: ActionInterruptionContext).actor).toBe(actor)
	expect((incoming :: ActionInterruptionContext).actionId).toBe("Action.Channel")
	expect((incoming :: ActionInterruptionContext).parameters).toBe(parameters)
	expect(interruptedReason).toBe("ActionLockPreempted")
	expect((controller:EndAction(owner.sequenceId))).toBe(false)
	expect((controller:EndAction(claimant.sequenceId))).toBe(true)
end)

it("denied scoped preemption leaves both Actions and lock ownership intact", function()
	local claimantContext: ActionExecutionContext? = nil
	local ownerContext: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				claimantContext = value
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onStart = function(value: ActionExecutionContext): ()
				ownerContext = value
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (claimantContext :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(claim).toBeNil()
	expect(reason).toBe("ActionLockClaimDenied")
	expect((claimantContext :: ActionExecutionContext):IsActive()).toBe(true)
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
end)

it("rejects a scoped claim if a reentrant decision terminates its claimant", function()
	local claimantContext: ActionExecutionContext? = nil
	local ownerContext: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionExecutionContext): ()
				claimantContext = context
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Channel" },
			onStart = function(context: ActionExecutionContext): ()
				ownerContext = context
			end,
			canBeInterruptedBy = function(): boolean
				(claimantContext :: ActionExecutionContext):End()
				return true
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (claimantContext :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(claim).toBeNil()
	expect(reason).toBe("ActionInstanceNotActive")
	expect((claimantContext :: ActionExecutionContext):IsActive()).toBe(false)
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(true)
end)

it("abandons a multi-owner scoped claim when one owner denies preemption", function()
	local claimantContext: ActionExecutionContext? = nil
	local ownerContexts: { ActionExecutionContext } = {}
	local interrupted: { string } = {}
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionExecutionContext): ()
				claimantContext = context
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Channel" },
			onStart = function(context: ActionExecutionContext): ()
				table.insert(ownerContexts, context)
			end,
			canBeInterruptedBy = function(): boolean
				return true
			end,
			onInterrupt = function(): ()
				table.insert(interrupted, "Sprint")
			end,
		},
		{
			id = "Action.Aim",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Combat" },
			interruptibleBy = { "Action.Channel" },
			onStart = function(context: ActionExecutionContext): ()
				table.insert(ownerContexts, context)
			end,
			canBeInterruptedBy = function(): boolean
				return false
			end,
			onInterrupt = function(): ()
				table.insert(interrupted, "Aim")
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Aim").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (claimantContext :: ActionExecutionContext):ClaimLocks({
		"Movement",
		"Combat",
	})
	expect(claim).toBeNil()
	expect(reason).toBe("ActionLockClaimDenied")
	expect(interrupted).toEqual({})
	expect(ownerContexts[1]:IsActive()).toBe(true)
	expect(ownerContexts[2]:IsActive()).toBe(true)
	expect((claimantContext :: ActionExecutionContext):IsActive()).toBe(true)
end)

it("commits a multi-owner scoped preemption before the first interruption hook", function()
	local claimantContext: ActionExecutionContext? = nil
	local ownerContexts: { ActionExecutionContext } = {}
	local interrupted: { string } = {}
	local bothRetiredBeforeDispatch: boolean? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionExecutionContext): ()
				claimantContext = context
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Channel" },
			onStart = function(context: ActionExecutionContext): ()
				table.insert(ownerContexts, context)
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				if #interrupted == 0 then
					bothRetiredBeforeDispatch = not ownerContexts[1]:IsActive() and not ownerContexts[2]:IsActive()
				end
				table.insert(interrupted, "Sprint:" .. reason)
			end,
		},
		{
			id = "Action.Aim",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Combat" },
			interruptibleBy = { "Action.Channel" },
			onStart = function(context: ActionExecutionContext): ()
				table.insert(ownerContexts, context)
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				if #interrupted == 0 then
					bothRetiredBeforeDispatch = not ownerContexts[1]:IsActive() and not ownerContexts[2]:IsActive()
				end
				table.insert(interrupted, "Aim:" .. reason)
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect(controller:RequestAction("Action.Aim").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (claimantContext :: ActionExecutionContext):ClaimLocks({
		"Movement",
		"Combat",
	})
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	expect(bothRetiredBeforeDispatch).toBe(true)
	expect(interrupted).toEqual({ "Sprint:ActionLockPreempted", "Aim:ActionLockPreempted" })
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = false, reason = "ActionLockConflict" })
end)

it("preempting a scoped lock interrupts the whole owner Action", function()
	local ownerContext: ActionExecutionContext? = nil
	local interruptedReason: string? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			interruptibleBy = { "Action.Sprint" },
			onStart = function(value: ActionExecutionContext): ()
				ownerContext = value
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				interruptedReason = reason
			end,
		},
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Channel")
	local claim: LockClaim?, reason: string? = (ownerContext :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	expect((ownerContext :: ActionExecutionContext):IsActive()).toBe(false)
	expect(interruptedReason).toBe("ActionLockPreempted")
	expect((controller:EndAction(owner.sequenceId))).toBe(false)
	local acquiredClaim: LockClaim = claim :: LockClaim
	acquiredClaim:Release()
end)

it("preserves a lifetime lock after releasing an overlapping scoped claim", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
		{ id = "Action.Roll", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	local owner: any = controller:RequestAction("Action.Sprint")
	local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	local acquiredClaim: LockClaim = claim :: LockClaim
	acquiredClaim:Release()
	expect(controller:RequestAction("Action.Roll")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	expect((controller:EndAction(owner.sequenceId))).toBe(true)
	expect(controller:RequestAction("Action.Roll").accepted).toBe(true)
end)

it("preserves a scoped lock until its last same-owner claim is released", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
		{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	local first: LockClaim?, firstReason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	local second: LockClaim?, secondReason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(firstReason).toBeNil()
	expect(secondReason).toBeNil()
	expect(first).never.toBeNil()
	expect(second).never.toBeNil()
	local firstClaim: LockClaim = first :: LockClaim
	local secondClaim: LockClaim = second :: LockClaim
	firstClaim:Release()
	firstClaim:Release()
	expect(controller:RequestAction("Action.Sprint")).toEqual({ accepted = false, reason = "ActionLockConflict" })
	secondClaim:Release()
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
end)

it("automatically releases every scoped claim on End and Interrupt", function()
	for _, terminal: string in { "End", "Interrupt" } do
		local context: ActionExecutionContext? = nil
		loadDefinitions({
			{
				id = "Action.Channel",
				visibility = "ServerOnly",
				autoGrant = true,
				onStart = function(value: ActionExecutionContext): ()
					context = value
				end,
			},
			{ id = "Action.Sprint", visibility = "ServerOnly", autoGrant = true, locks = { "Movement" } },
		})
		local _actor: Actor, controller: ActionController = createController()
		local owner: any = controller:RequestAction("Action.Channel")
		local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
		expect(reason).toBeNil()
		expect(claim).never.toBeNil()
		if terminal == "End" then
			expect((controller:EndAction(owner.sequenceId))).toBe(true)
		elseif terminal == "Interrupt" then
			expect((controller:InterruptAction(owner.sequenceId, "Manual"))).toBe(true)
		end
		expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
		local acquiredClaim: LockClaim = claim :: LockClaim
		acquiredClaim:Release()
		acquiredClaim:Release()
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("makes outstanding claim handles harmless after controller destruction", function()
	local context: ActionExecutionContext? = nil
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(value: ActionExecutionContext): ()
				context = value
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	local claim: LockClaim?, reason: string? = (context :: ActionExecutionContext):ClaimLocks({ "Movement" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	controller:Destroy()
	local acquiredClaim: LockClaim = claim :: LockClaim
	acquiredClaim:Release()
	acquiredClaim:Release()
	expect((context :: ActionExecutionContext):IsActive()).toBe(false)
end)

it("allows an update callback to acquire a claim and preempt another Action safely", function()
	local updated: number = 0
	local claimReason: string? = nil
	local interrupted: number = 0
	loadDefinitions({
		{
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				updated += 1
				local _claim: LockClaim?
				_claim, claimReason = context:ClaimLocks({ "Movement" })
			end,
		},
		{
			id = "Action.Sprint",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Movement" },
			interruptibleBy = { "Action.Channel" },
			onInterrupt = function(): ()
				interrupted += 1
			end,
		},
	})
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:RequestAction("Action.Channel").accepted).toBe(true)
	expect(controller:RequestAction("Action.Sprint").accepted).toBe(true)
	ActionControllerUpdates._heartbeatForTests(0.05)
	expect(updated).toBe(1)
	expect(claimReason).toBeNil()
	expect(interrupted).toBe(1)
	ActionControllerUpdates._heartbeatForTests(0.05)
	expect(updated).toBe(2)
end)
