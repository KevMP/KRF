--!strict
local ActionTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local ActionControllerHooks = require(script.Parent.ActionControllerHooks)
local ActionControllerUpdates = require(script.Parent.ActionControllerUpdates)
local TagTypes = require(script.Parent.Parent.Parent.Tags.types)
local ResourceTypes = require(script.Parent.Parent.Parent.Resource.types)
local ActionControllerResources = require(script.Parent.ActionControllerResources)
local ActionMutationJournal = require(script.Parent.ActionMutationJournal)
local ActorPublicationLifecycle = require(script.Parent.Parent.Parent.Networking.utils.ActorPublicationLifecycle)

type Actor = ActorTypes.Actor
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type ActionLifecycleEvent = ActionTypes.ActionLifecycleEvent
type ActionInterruptedEvent = ActionTypes.ActionInterruptedEvent
type InternalActionImplementation = ActionTypes.InternalActionImplementation
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type LockClaim = ActionTypes.LockClaim
type InternalTagController = TagTypes.InternalTagController
type TagMutationReceipt = TagTypes.TagMutationReceipt

type InternalActionInstance = {
	sequenceId: number,
	identity: {},
	actionId: string,
	definition: LoadedActionDefinition,
	implementation: InternalActionImplementation,
	context: ActionExecutionContext,
	ownedLockReasons: { [string]: number },
	onStartThread: thread?,
	ownedTagReceipts: { TagMutationReceipt },
	tagController: InternalTagController?,
	terminalTagEvents: { TagTypes.TagMutationEvent },
	startedIssued: boolean,
}

export type ActionControllerInstances = {
	ObserveMutations: (
		self: ActionControllerInstances,
		callback: ({ ActionTypes.ActionReplicationMutation }) -> ()
	) -> () -> (),
	GetActiveReplicationState: (self: ActionControllerInstances) -> { ActionTypes.ActionReplicationIdentity },
	Start: (
		self: ActionControllerInstances,
		actionId: string,
		implementation: InternalActionImplementation,
		parameters: any?,
		definition: LoadedActionDefinition,
		validateRequest: () -> string?
	) -> (number?, string?),
	RequestStop: (self: ActionControllerInstances, sequenceId: number, parameters: any?) -> (boolean, string?),
	EndAction: (self: ActionControllerInstances, sequenceId: number) -> (boolean, string?),
	InterruptAction: (self: ActionControllerInstances, sequenceId: number, reason: string) -> (boolean, string?),
	Destroy: (self: ActionControllerInstances) -> (),
}

local ActionControllerInstancesModule = {}

local function validSequenceId(sequenceId: any): boolean
	return type(sequenceId) == "number" and sequenceId >= 1 and sequenceId <= 4294967295 and sequenceId % 1 == 0
end

function ActionControllerInstancesModule.new(
	actor: Actor,
	ownedSignals: SignalTypes.OwnedSignals,
	startedSignal: SignalTypes.Signal<ActionLifecycleEvent>,
	endedSignal: SignalTypes.Signal<ActionLifecycleEvent>,
	interruptedSignal: SignalTypes.Signal<ActionInterruptedEvent>,
	controllerState: { destroyed: boolean },
	initialSequenceIdForTests: number?
): ActionControllerInstances
	local instances: ActionControllerInstances = {} :: ActionControllerInstances
	local nextSequenceId: number = initialSequenceIdForTests or 1
	local activeBySequenceId: { [number]: InternalActionInstance } = {}
	local activeVisibleCount: number = 0
	local lockOwners: { [string]: InternalActionInstance } = {}
	local journal: ActionMutationJournal.ActionMutationJournal = ActionMutationJournal.new()

	local function mutation(
		instance: InternalActionInstance,
		kind: ActionTypes.ActionReplicationMutationKind
	): ActionTypes.ActionReplicationMutation
		return table.freeze({ kind = kind, actionId = instance.actionId, sequenceId = instance.sequenceId })
	end

	-- Closing publication can fail after authority is committed. Retain the first
	-- failure locally so public delivery and authored hooks still complete once.
	local function withCommit(
		callback: () -> { ActionTypes.ActionReplicationMutation }
	): ActionMutationJournal.MutationFailure?
		local failure: ActionMutationJournal.MutationFailure? = nil
		local committed: boolean = false

		local success: boolean, detail: any = pcall(function()
			ActorPublicationLifecycle.WithActorCommit(actor, function()
				local mutations: { ActionTypes.ActionReplicationMutation } = callback()
				committed = true

				local resources: ResourceTypes.InternalResourceController? =
					actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?

				if resources ~= nil then
					local resourceSuccess: boolean, resourceFailure: any = pcall(function()
						resources:_rethrowMutationFailure()
					end)

					if not resourceSuccess then
						failure = { value = resourceFailure }
					end
				end

				local observerFailure: ActionMutationJournal.MutationFailure? = journal:Commit(mutations)

				if failure == nil then
					failure = observerFailure
				end
			end)
		end)

		if not success and not committed then
			error(detail, 0)
		end

		if not success and failure == nil then
			failure = { value = detail }
		end

		return failure
	end

	function instances:ObserveMutations(callback: ({ ActionTypes.ActionReplicationMutation }) -> ()): () -> ()
		return journal:Observe(callback)
	end

	function instances:GetActiveReplicationState(): { ActionTypes.ActionReplicationIdentity }
		local identities: { ActionTypes.ActionReplicationIdentity } = {}

		for _, instance: InternalActionInstance in activeBySequenceId do
			table.insert(identities, table.freeze({ actionId = instance.actionId, sequenceId = instance.sequenceId }))
		end

		table.sort(
			identities,
			function(left: ActionTypes.ActionReplicationIdentity, right: ActionTypes.ActionReplicationIdentity): boolean
				return left.sequenceId < right.sequenceId
			end
		)

		return table.freeze(identities)
	end

	local function getTagController(): InternalTagController?
		return actor:GetController("TagController") :: InternalTagController?
	end

	local function isActive(instance: InternalActionInstance): boolean
		return activeBySequenceId[instance.sequenceId] == instance
	end

	local function retireStart(instance: InternalActionInstance): ()
		local startThread: thread? = instance.onStartThread

		if startThread == nil then
			return
		end

		if coroutine.running() ~= startThread then
			ActionControllerHooks.CancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	local function commitTerminal(instance: InternalActionInstance): boolean
		if not isActive(instance) then
			return false
		end

		activeBySequenceId[instance.sequenceId] = nil

		if instance.definition.visibility == "ClientVisible" then
			activeVisibleCount -= 1
		end

		for lockId: string in instance.ownedLockReasons do
			if lockOwners[lockId] == instance then
				lockOwners[lockId] = nil
			end
		end

		table.clear(instance.ownedLockReasons)

		if instance.implementation.onUpdate ~= nil then
			ActionControllerUpdates.Remove(instances, instance.sequenceId)
		end

		retireStart(instance)
		local tags: InternalTagController? = instance.tagController

		if tags ~= nil and #instance.ownedTagReceipts > 0 then
			tags:_beginMutationBatch()

			for _, handle: TagMutationReceipt in instance.ownedTagReceipts do
				tags:_removeByReceipt(handle)
			end

			instance.terminalTagEvents = tags:_finishMutationBatch()
		end

		table.clear(instance.ownedTagReceipts)

		return true
	end

	local function addLockReason(instance: InternalActionInstance, lockId: string): ()
		instance.ownedLockReasons[lockId] = (instance.ownedLockReasons[lockId] or 0) + 1
		lockOwners[lockId] = instance
	end

	local function removeLockReason(instance: InternalActionInstance, lockId: string): ()
		local reasons: number? = instance.ownedLockReasons[lockId]

		if reasons == nil then
			return
		end

		if reasons > 1 then
			instance.ownedLockReasons[lockId] = reasons - 1
		else
			instance.ownedLockReasons[lockId] = nil

			if lockOwners[lockId] == instance then
				lockOwners[lockId] = nil
			end
		end
	end

	local function lifecycleEvent(instance: InternalActionInstance): ActionLifecycleEvent
		return {
			actor = actor,
			actionId = instance.actionId,
			sequenceId = instance.sequenceId,
		}
	end

	local function issueStarted(instance: InternalActionInstance): ()
		if instance.startedIssued then
			return
		end

		-- A prior owner's signal listener can terminate this accepted instance
		-- before the enclosing activation reaches its Started signal.
		instance.startedIssued = true
		startedSignal:Fire(lifecycleEvent(instance))
	end

	local function dispatchTerminalTags(instance: InternalActionInstance): ()
		local tags: InternalTagController? = instance.tagController

		if tags ~= nil then
			local events: { TagTypes.TagMutationEvent } = instance.terminalTagEvents

			instance.terminalTagEvents = {}
			tags:_dispatchMutationEvents(events)
		end
	end

	-- Notification failure cannot undo committed activation/termination. Complete
	-- the remaining delivery and lifecycle hooks before returning the first error.
	local function withNotifications(
		notify: (attempt: (callback: () -> ()) -> ()) -> (),
		committedFailure: ActionMutationJournal.MutationFailure?
	): ()
		local failed: boolean = committedFailure ~= nil
		local failure: any = if committedFailure ~= nil then committedFailure.value else nil

		local function attempt(callback: () -> ()): ()
			local success: boolean, reason: any = pcall(callback)

			if not success and not failed then
				failed, failure = true, reason
			end
		end

		-- Take the transaction's error before lifecycle listeners can reenter a
		-- Resource mutation and drain its pending public notifications themselves.
		local resources: ResourceTypes.InternalResourceController? =
			actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?

		if resources ~= nil then
			attempt(function()
				(resources :: ResourceTypes.InternalResourceController):_rethrowMutationFailure()
			end)
		end

		ownedSignals:WithDeferredDestroy(function()
			notify(attempt)
		end)

		if failed then
			error(failure, 0)
		end
	end

	local function dispatchEnd(instance: InternalActionInstance, failure: ActionMutationJournal.MutationFailure?): ()
		withNotifications(function(attempt)
			issueStarted(instance)
			endedSignal:Fire(lifecycleEvent(instance))

			attempt(function()
				dispatchTerminalTags(instance)
			end)

			local callback = instance.implementation.onEnd

			if callback ~= nil then
				local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
					ActionControllerHooks.RunNonSuspending(callback, instance.context)

				if not succeeded then
					ActionControllerHooks.WarnFailure(actor, instance.actionId, "onEnd", failureDetail or failureKind)
				end
			end
		end, failure)
	end

	local function issueInterrupted(instance: InternalActionInstance, reason: string): ()
		issueStarted(instance)

		interruptedSignal:Fire({
			actor = actor,
			actionId = instance.actionId,
			sequenceId = instance.sequenceId,
			reason = reason,
		})
	end

	local function invokeInterrupt(instance: InternalActionInstance, reason: string): ()
		local callback = instance.implementation.onInterrupt

		if callback ~= nil then
			local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
				ActionControllerHooks.RunNonSuspending(callback, instance.context, reason)

			if not succeeded then
				ActionControllerHooks.WarnFailure(actor, instance.actionId, "onInterrupt", failureDetail or failureKind)
			end
		end
	end

	local function dispatchInterrupt(
		instance: InternalActionInstance,
		reason: string,
		failure: ActionMutationJournal.MutationFailure?
	): ()
		withNotifications(function(attempt)
			issueInterrupted(instance, reason)

			attempt(function()
				dispatchTerminalTags(instance)
			end)

			invokeInterrupt(instance, reason)
		end, failure)
	end

	local function normalizeLockIds(lockIds: any): { string }?
		if type(lockIds) ~= "table" then
			return nil
		end

		local count: number = 0

		for key in lockIds do
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
				return nil
			end

			count += 1
		end

		local normalized: { string } = {}
		local seen: { [string]: boolean } = {}

		for index: number = 1, count do
			local lockId: any = lockIds[index]

			if type(lockId) ~= "string" or lockId == "" or seen[lockId] then
				return nil
			end

			seen[lockId] = true
			table.insert(normalized, lockId)
		end

		return normalized
	end

	local function collectConflicts(
		lockIds: { string },
		incomingInstance: InternalActionInstance?
	): { InternalActionInstance }
		local conflicts: { InternalActionInstance } = {}
		local seen: { [number]: boolean } = {}

		for _, lockId: string in lockIds do
			local owner: InternalActionInstance? = lockOwners[lockId]

			if owner ~= nil and owner ~= incomingInstance and not seen[owner.sequenceId] then
				seen[owner.sequenceId] = true
				table.insert(conflicts, owner)
			end
		end

		table.sort(conflicts, function(left: InternalActionInstance, right: InternalActionInstance): boolean
			return left.sequenceId < right.sequenceId
		end)

		return conflicts
	end

	local function sameConflicts(left: { InternalActionInstance }, right: { InternalActionInstance }): boolean
		if #left ~= #right then
			return false
		end

		for index: number, owner: InternalActionInstance in left do
			if right[index] ~= owner then
				return false
			end
		end

		return true
	end

	local function decideInterruption(
		owner: InternalActionInstance,
		incomingContext: ActionTypes.ActionInterruptionContext
	): (boolean, string?)
		local allowlisted: boolean = false

		for _, allowedId: string in owner.definition.interruptibleBy do
			if allowedId == incomingContext.actionId then
				allowlisted = true
				break
			end
		end

		if not allowlisted then
			return false, "ActionLockConflict"
		end

		local callback = owner.implementation.canBeInterruptedBy

		if callback == nil then
			return true, nil
		end

		local succeeded: boolean, allowed: any, _second: any, failureKind: string?, failureDetail: any =
			ActionControllerHooks.RunNonSuspending(callback, owner.context, incomingContext)

		if not succeeded then
			warn(
				"[ActionController] canBeInterruptedBy failed actorId="
					.. actor:GetId()
					.. " actionId="
					.. owner.actionId
					.. " sequenceId="
					.. tostring(owner.sequenceId)
					.. " reason="
					.. tostring(failureDetail or failureKind)
			)

			return false,
				if failureKind == "Yielded" then "ActionInterruptDecisionYielded" else "ActionInterruptDecisionFailed"
		end

		if type(allowed) ~= "boolean" then
			warn(
				"[ActionController] canBeInterruptedBy invalid result actorId="
					.. actor:GetId()
					.. " actionId="
					.. owner.actionId
					.. " sequenceId="
					.. tostring(owner.sequenceId)
			)

			return false, "ActionInterruptDecisionInvalidResult"
		end

		return allowed, if allowed then nil else "ActionLockConflict"
	end

	local function resolveConflicts(
		lockIds: { string },
		incomingInstance: InternalActionInstance?,
		incomingContext: ActionTypes.ActionInterruptionContext
	): ({ InternalActionInstance }?, string?)
		for _attempt: number = 1, 64 do
			if incomingInstance ~= nil and not isActive(incomingInstance) then
				return nil, "ActionInstanceNotActive"
			end

			local conflicts: { InternalActionInstance } = collectConflicts(lockIds, incomingInstance)
			local stale: boolean = false

			for _, owner: InternalActionInstance in conflicts do
				local allowed: boolean, reason: string? = decideInterruption(owner, incomingContext)

				if incomingInstance ~= nil and not isActive(incomingInstance) then
					return nil, "ActionInstanceNotActive"
				end

				if not sameConflicts(conflicts, collectConflicts(lockIds, incomingInstance)) then
					stale = true
					break
				end

				if not allowed then
					return nil, reason
				end
			end

			if not stale then
				return conflicts, nil
			end
		end

		return nil, "ActionLockConflict"
	end

	local function claimLocks(instance: InternalActionInstance, lockIds: { string }): (LockClaim?, string?)
		if not isActive(instance) then
			return nil, "ActionInstanceNotActive"
		end

		local normalized: { string }? = normalizeLockIds(lockIds)

		if normalized == nil then
			return nil, "ActionLockRequestInvalid"
		end

		local incomingContext: ActionTypes.ActionInterruptionContext = table.freeze({
			actor = actor,
			actionId = instance.actionId,
			parameters = instance.context.parameters,
		})

		local conflicts: { InternalActionInstance }?, reason: string? =
			resolveConflicts(normalized, instance, incomingContext)

		if conflicts == nil then
			return nil, if reason == "ActionLockConflict" then "ActionLockClaimDenied" else reason
		end

		if controllerState.destroyed or not isActive(instance) then
			return nil, "ActionInstanceNotActive"
		end

		local tags: InternalTagController? = getTagController()
		local tagEvents: { TagTypes.TagMutationEvent } = {}

		local failure: ActionMutationJournal.MutationFailure? = withCommit(
			function(): { ActionTypes.ActionReplicationMutation }
				local mutations: { ActionTypes.ActionReplicationMutation } = {}

				if tags ~= nil then
					tags:_beginMutationBatch()
				end

				for _, owner: InternalActionInstance in conflicts do
					commitTerminal(owner)
					table.insert(mutations, mutation(owner, "Interrupted"))
				end

				for _, lockId: string in normalized do
					addLockReason(instance, lockId)
				end

				tagEvents = if tags ~= nil then tags:_finishMutationBatch() else {}

				return mutations
			end
		)

		local released: boolean = false

		local claim: LockClaim = {
			Release = function(_self: LockClaim): ()
				if released then
					return
				end

				released = true

				if not isActive(instance) then
					return
				end

				for _, lockId: string in normalized do
					removeLockReason(instance, lockId)
				end
			end,
		}

		table.freeze(claim)

		withNotifications(function(attempt)
			for _, owner: InternalActionInstance in conflicts do
				issueInterrupted(owner, "ActionLockPreempted")
			end

			if tags ~= nil then
				attempt(function()
					(tags :: InternalTagController):_dispatchMutationEvents(tagEvents)
				end)
			end

			for _, owner: InternalActionInstance in conflicts do
				attempt(function()
					dispatchTerminalTags(owner)
				end)
			end

			for _, owner: InternalActionInstance in conflicts do
				invokeInterrupt(owner, "ActionLockPreempted")
			end
		end, failure)

		return claim :: LockClaim?, nil
	end

	local function endById(sequenceId: number): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end

		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end

		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]

		if instance == nil then
			return false, "ActionInstanceNotActive"
		end

		local failure: ActionMutationJournal.MutationFailure? = withCommit(
			function(): { ActionTypes.ActionReplicationMutation }
				commitTerminal(instance)

				return { mutation(instance, "Ended") }
			end
		)

		dispatchEnd(instance, failure)

		return true, nil
	end

	local function interruptById(sequenceId: number, reason: string): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end

		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end

		if type(reason) ~= "string" or reason == "" then
			return false, "ActionInterruptReasonInvalid"
		end

		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]

		if instance == nil then
			return false, "ActionInstanceNotActive"
		end

		local failure: ActionMutationJournal.MutationFailure? = withCommit(
			function(): { ActionTypes.ActionReplicationMutation }
				commitTerminal(instance)

				return { mutation(instance, "Interrupted") }
			end
		)

		dispatchInterrupt(instance, reason, failure)

		return true, nil
	end

	local function commitActivation(
		actionId: string,
		implementation: InternalActionImplementation,
		parameters: any?,
		definition: LoadedActionDefinition,
		ownedTagReceipts: { TagMutationReceipt },
		tags: InternalTagController?
	): InternalActionInstance
		local sequenceId: number = nextSequenceId
		nextSequenceId += 1
		local identity: {} = {}
		local instance: InternalActionInstance = {} :: InternalActionInstance

		local context: ActionExecutionContext = {
			actor = actor,
			actionId = actionId,
			sequenceId = sequenceId,
			parameters = parameters,
			IsActive = function(_self: ActionExecutionContext): boolean
				local active: InternalActionInstance? = activeBySequenceId[sequenceId]

				return active ~= nil and active.identity == identity
			end,
			End = function(_self: ActionExecutionContext): (boolean, string?)
				return endById(sequenceId)
			end,
			Interrupt = function(_self: ActionExecutionContext, reason: string): (boolean, string?)
				return interruptById(sequenceId, reason)
			end,
			ClaimLocks = function(_self: ActionExecutionContext, lockIds: { string }): (LockClaim?, string?)
				return claimLocks(instance, lockIds)
			end,
		}

		table.freeze(context)
		instance.sequenceId = sequenceId
		instance.identity = identity
		instance.actionId = actionId
		instance.definition = definition
		instance.implementation = implementation
		instance.context = context
		instance.ownedLockReasons = {}
		instance.onStartThread = nil
		instance.ownedTagReceipts = ownedTagReceipts
		instance.tagController = tags
		instance.terminalTagEvents = {}
		instance.startedIssued = false
		activeBySequenceId[sequenceId] = instance

		if definition.visibility == "ClientVisible" then
			activeVisibleCount += 1
		end

		for _, lockId: string in definition.locks do
			addLockReason(instance, lockId)
		end

		local updateCallback = implementation.onUpdate

		if updateCallback ~= nil then
			ActionControllerUpdates.Register(
				instances,
				actor,
				actionId,
				sequenceId,
				context,
				updateCallback,
				interruptById
			)
		end

		return instance
	end

	local function beginStart(instance: InternalActionInstance): ()
		local callback = instance.implementation.onStart

		if callback == nil or not isActive(instance) then
			return
		end

		local startThread: thread = coroutine.create(function()
			local succeeded: boolean, failure: any = pcall(callback, instance.context)
			instance.onStartThread = nil

			if not succeeded then
				ActionControllerHooks.WarnFailure(actor, instance.actionId, "onStart", failure)

				if isActive(instance) then
					interruptById(instance.sequenceId, "ActionStartFailed")
				end
			end
		end)

		instance.onStartThread = startThread
		local resumed: boolean, failure: any = coroutine.resume(startThread)

		if not resumed then
			instance.onStartThread = nil
			ActionControllerHooks.WarnFailure(actor, instance.actionId, "onStart", failure)

			if isActive(instance) then
				interruptById(instance.sequenceId, "ActionStartFailed")
			end
		elseif coroutine.status(startThread) ~= "dead" and not isActive(instance) then
			ActionControllerHooks.CancelSuspendedThread(startThread)
			instance.onStartThread = nil
		end
	end

	function instances:Start(
		actionId: string,
		implementation: InternalActionImplementation,
		parameters: any?,
		definition: LoadedActionDefinition,
		validateRequest: () -> string?
	): (number?, string?)
		if not validSequenceId(nextSequenceId) then
			return nil, "ActionSequenceIdExhausted"
		end

		local incomingContext: ActionTypes.ActionInterruptionContext = table.freeze({
			actor = actor,
			actionId = actionId,
			parameters = parameters,
		})

		local conflicts: { InternalActionInstance }?, reason: string? =
			resolveConflicts(definition.locks, nil, incomingContext)

		if conflicts == nil then
			return nil, reason
		end

		local availabilityReason: string? = validateRequest()

		if availabilityReason ~= nil then
			return nil, availabilityReason
		end

		-- Interruption decisions may reenter the controller. Recheck the shared
		-- namespace and prospective visible capacity after every authored decision.
		if not validSequenceId(nextSequenceId) then
			return nil, "ActionSequenceIdExhausted"
		end

		if definition.visibility == "ClientVisible" then
			local visibleCount: number = activeVisibleCount + 1

			for _, owner: InternalActionInstance in conflicts do
				if owner.definition.visibility == "ClientVisible" then
					visibleCount -= 1
				end
			end

			if visibleCount > 256 then
				return nil, "ActionVisibleInstanceLimitReached"
			end
		end

		local tags: InternalTagController? = getTagController()

		if #definition.activeTags > 0 or #definition.appliedTags > 0 then
			if tags == nil then
				local first = definition.activeTags[1] or definition.appliedTags[1]

				return nil, "ActionTagActivationFailed:" .. first.id
			end

			local tagReason: string? = tags:_validateApplications(definition.activeTags)
				or tags:_validateApplications(definition.appliedTags)

			if tagReason ~= nil then
				return nil, "ActionTagActivationFailed:" .. tagReason
			end
		end

		-- All fallible Tag validation precedes preemption. No consumer work or
		-- yielding occurs between validation and the complete authoritative commit.
		local resourcePlan: ActionControllerResources.ResourcePlan?, resourceReason: string? =
			ActionControllerResources.Resolve(actor, definition)

		if resourceReason ~= nil then
			return nil, resourceReason
		end

		local resources: ResourceTypes.InternalResourceController? = if resourcePlan ~= nil
			then resourcePlan.controller
			else actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?

		if resources ~= nil and resources:_isDestroyed() then
			resources = nil
		end

		local instance: InternalActionInstance
		local tagEvents: { TagTypes.TagMutationEvent } = {}

		local failure: ActionMutationJournal.MutationFailure? = withCommit(
			function(): { ActionTypes.ActionReplicationMutation }
				if resources ~= nil then
					resources:_beginMutationBatch()
				end

				-- Spend the fixed pre-transaction price before any same-transaction derived changes.
				if resourcePlan ~= nil then
					resourcePlan.commit()
				end

				if tags ~= nil then
					tags:_beginMutationBatch()
				end

				for _, owner: InternalActionInstance in conflicts do
					commitTerminal(owner)
				end

				local ownedTagReceipts: { TagMutationReceipt } = {}

				if tags ~= nil then
					for _, application in definition.activeTags do
						local added: boolean, applicationReason: string?, receipt: TagMutationReceipt? =
							tags:_addTagWithReceipt(application.id, { duration = application.duration })

						assert(added, applicationReason or "ActionTagActivationFailed")

						if receipt ~= nil then
							if receipt.previousVersion == nil then
								table.insert(ownedTagReceipts, receipt)
							else
								-- Only advance ownership of a record already created by this instance.
								for index: number, owned: TagMutationReceipt in ownedTagReceipts do
									if owned.record == receipt.record and owned.version == receipt.previousVersion then
										ownedTagReceipts[index] = receipt
										break
									end
								end
							end
						end
					end

					for _, application in definition.appliedTags do
						local added: boolean, applicationReason: string? =
							tags:_addTagWithReceipt(application.id, { duration = application.duration })

						assert(added, applicationReason or "ActionTagActivationFailed")
					end
				end

				instance = commitActivation(actionId, implementation, parameters, definition, ownedTagReceipts, tags)

				tagEvents = if tags ~= nil then tags:_finishMutationBatch() else {}

				if resources ~= nil then
					resources:_finishMutationBatch()
				end

				local mutations: { ActionTypes.ActionReplicationMutation } = {}

				for _, owner: InternalActionInstance in conflicts do
					table.insert(mutations, mutation(owner, "Interrupted"))
				end

				table.insert(mutations, mutation(instance, "Started"))

				return mutations
			end
		)

		withNotifications(function(attempt)
			for _, owner: InternalActionInstance in conflicts do
				issueInterrupted(owner, "ActionLockPreempted")
			end

			issueStarted(instance)

			if tags ~= nil then
				attempt(function()
					(tags :: InternalTagController):_dispatchMutationEvents(tagEvents)
				end)
			end

			for _, owner: InternalActionInstance in conflicts do
				attempt(function()
					dispatchTerminalTags(owner)
				end)
			end

			if resources ~= nil then
				attempt(function()
					(resources :: ResourceTypes.InternalResourceController):_dispatchChanges()
				end)
			end

			for _, owner: InternalActionInstance in conflicts do
				invokeInterrupt(owner, "ActionLockPreempted")
			end

			if isActive(instance) then
				beginStart(instance)
			end
		end, failure)

		return instance.sequenceId, nil
	end

	function instances:RequestStop(sequenceId: number, parameters: any?): (boolean, string?)
		if controllerState.destroyed then
			return false, "ActionControllerDestroyed"
		end

		if not validSequenceId(sequenceId) then
			return false, "ActionSequenceIdInvalid"
		end

		local instance: InternalActionInstance? = activeBySequenceId[sequenceId]

		if instance == nil then
			return false, "ActionInstanceNotActive"
		end

		local callback = instance.implementation.onStopRequested

		if callback ~= nil then
			local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
				ActionControllerHooks.RunNonSuspending(callback, instance.context, { parameters = parameters })

			if not succeeded then
				ActionControllerHooks.WarnFailure(
					actor,
					instance.actionId,
					"onStopRequested",
					failureDetail or failureKind
				)
			end
		end

		return true, nil
	end

	function instances:EndAction(sequenceId: number): (boolean, string?)
		return endById(sequenceId)
	end

	function instances:InterruptAction(sequenceId: number, reason: string): (boolean, string?)
		return interruptById(sequenceId, reason)
	end

	function instances:Destroy(): ()
		local activeInstances: { InternalActionInstance } = {}

		for _, instance: InternalActionInstance in activeBySequenceId do
			table.insert(activeInstances, instance)
		end

		table.sort(activeInstances, function(left: InternalActionInstance, right: InternalActionInstance): boolean
			return left.sequenceId < right.sequenceId
		end)

		local tags: InternalTagController? = getTagController()

		local tagEvents: { TagTypes.TagMutationEvent } = {}

		local failure: ActionMutationJournal.MutationFailure? = withCommit(
			function(): { ActionTypes.ActionReplicationMutation }
				local mutations: { ActionTypes.ActionReplicationMutation } = {}

				if tags ~= nil then
					tags:_beginMutationBatch()
				end

				for _, instance: InternalActionInstance in activeInstances do
					commitTerminal(instance)
					table.insert(mutations, mutation(instance, "Interrupted"))
				end

				tagEvents = if tags ~= nil then tags:_finishMutationBatch() else {}

				return mutations
			end
		)

		journal:Destroy()

		withNotifications(function(attempt)
			for _, instance: InternalActionInstance in activeInstances do
				issueInterrupted(instance, "ActionControllerDestroyed")
			end

			if tags ~= nil then
				attempt(function()
					(tags :: InternalTagController):_dispatchMutationEvents(tagEvents)
				end)
			end

			for _, instance: InternalActionInstance in activeInstances do
				attempt(function()
					dispatchTerminalTags(instance)
				end)
			end

			for _, instance: InternalActionInstance in activeInstances do
				invokeInterrupt(instance, "ActionControllerDestroyed")
			end
		end, failure)
	end

	return instances
end

return ActionControllerInstancesModule
