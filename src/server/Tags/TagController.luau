--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local OwnedSignalsModule = require(SignalFolder.OwnedSignals)
local TagTypes = require(script.Parent.types)
local TagRegistry = require(script.Parent.TagRegistry)
local TagControllerEventUtils = require(script.Parent.utils.TagControllerEvent)
local TagControllerInstanceUtils = require(script.Parent.utils.TagControllerInstance)
local TagControllerStepUtils = require(script.Parent.utils.TagControllerStepUtils)
local TagControllerTickUtils = require(script.Parent.utils.TagControllerTickUtils)

local RunService: RunService = game:GetService("RunService")
local automaticStepIntervalSeconds: number = 0.1

export type TagController = TagTypes.TagController
export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition

type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type TagInstanceFactoryContext = TagControllerInstanceUtils.TagInstanceFactoryContext
type ActiveTagsById = TagControllerInstanceUtils.ActiveTagsById
type TagControllerEventContext = TagControllerEventUtils.TagControllerEventContext
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot
type TagApplication = TagTypes.TagApplication
type TagMutationReceipt = TagTypes.TagMutationReceipt
type AdvancingControllerEntry = TagControllerStepUtils.AdvancingControllerEntry
type StepTagInstanceResult = TagControllerStepUtils.StepTagInstanceResult
type InternalTagController = TagTypes.InternalTagController & {
	_activeTagsById: ActiveTagsById,
	_expireTimedInstance: (self: InternalTagController, tagRecord: TagInstanceRecord) -> boolean,
}
type ActiveTagSortRecord = {
	tagId: string,
	stackCount: number,
	oldestAppliedOrder: number,
	remainingDuration: number?,
}
type TagControllerModule = {
	new: (actor: ActorTypes.Actor) -> TagController,
	Step: (deltaTime: number) -> (),
	_setAutomaticSteppingEnabledForTests: (enabled: boolean) -> (),
}

local TagController: TagControllerModule = {} :: TagControllerModule
local HeartBeatConnection: RBXScriptConnection? = nil
local automaticSteppingEnabled: boolean = true
local automaticStepAccumulatorSeconds: number = 0

local advancingInstancesByController: { [TagController]: AdvancingControllerEntry } = {}

local function UpdateHeartbeatConnection(): ()
	local hasTimedControllers: boolean = next(advancingInstancesByController) ~= nil

	if automaticSteppingEnabled and hasTimedControllers then
		if HeartBeatConnection == nil then
			automaticStepAccumulatorSeconds = 0
			HeartBeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
				automaticStepAccumulatorSeconds += deltaTime

				if automaticStepAccumulatorSeconds < automaticStepIntervalSeconds then
					return
				end

				TagController.Step(automaticStepIntervalSeconds)
				automaticStepAccumulatorSeconds -= automaticStepIntervalSeconds
			end)
		end

		return
	end

	automaticStepAccumulatorSeconds = 0

	if HeartBeatConnection ~= nil then
		HeartBeatConnection:Disconnect()
		HeartBeatConnection = nil
	end
end

function TagController.new(actor: ActorTypes.Actor): TagController
	local tagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagExpiredSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignalsModule.new({
		tagAddedSignal,
		tagRemovedSignal,
		tagRefreshedSignal,
		tagChangedSignal,
		tagExpiredSignal,
	})

	local activeTagsById: ActiveTagsById = {}
	local destroyed: boolean = false
	local mutationBatchDepth: number = 0
	local deferredEvents: { TagTypes.TagMutationEvent } = {}
	local mutationObservers: { [TagTypes.TagMutationObserver]: boolean } = {}
	local recordVersions: { [TagInstanceRecord]: number } = setmetatable({}, { __mode = "k" }) :: { [TagInstanceRecord]: number }

	local factoryContext: TagInstanceFactoryContext = {
		nextAppliedOrder = 0,
	}

	local eventContext: TagControllerEventContext = {
		actor = actor,
		ownedSignals = ownedSignals,
		tagAddedSignal = tagAddedSignal,
		tagRemovedSignal = tagRemovedSignal,
		tagRefreshedSignal = tagRefreshedSignal,
		tagChangedSignal = tagChangedSignal,
		tagExpiredSignal = tagExpiredSignal,
	}

	local controller: InternalTagController = {} :: InternalTagController
	controller._activeTagsById = activeTagsById

	function controller:_observeMutations(observer: TagTypes.TagMutationObserver): () -> ()
		mutationObservers[observer] = true
		return function(): ()
			mutationObservers[observer] = nil
		end
	end

	local function commitDerivedState(events: { TagTypes.TagMutationEvent }): ()
		for observer: TagTypes.TagMutationObserver in mutationObservers do
			observer.Commit(events)
		end
	end

	local function dispatchDerivedEvents(): ()
		for observer: TagTypes.TagMutationObserver in mutationObservers do
			observer.Dispatch()
		end
	end

	local function dispatchEvent(kind: "Added" | "Removed" | "Refreshed" | "Expired", tagId: string): ()
		if kind == "Added" then
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
		elseif kind == "Removed" then
			TagControllerEventUtils.FireTagRemoved(eventContext, tagId)
		elseif kind == "Refreshed" then
			TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
		else
			TagControllerEventUtils.FireTagExpired(eventContext, tagId)
		end
	end

	local function fireEvent(kind: "Added" | "Removed" | "Refreshed" | "Expired", tagId: string): ()
		if mutationBatchDepth > 0 then
			table.insert(deferredEvents, { kind = kind, tagId = tagId })
			return
		end
		commitDerivedState({ { kind = kind, tagId = tagId } })
		dispatchEvent(kind, tagId)
		dispatchDerivedEvents()
	end

	function controller:_beginMutationBatch(): ()
		mutationBatchDepth += 1
	end

	-- Detach before dispatch so reentrant mutations complete in their own batch.
	function controller:_finishMutationBatch(): { TagTypes.TagMutationEvent }
		assert(mutationBatchDepth > 0, "TagMutationBatchNotOpen")
		mutationBatchDepth -= 1
		if mutationBatchDepth > 0 then
			return {}
		end
		local events: { TagTypes.TagMutationEvent } = deferredEvents
		deferredEvents = {}
		commitDerivedState(events)
		return events
	end

	function controller:_dispatchMutationEvents(events: { TagTypes.TagMutationEvent }): ()
		for _, event: TagTypes.TagMutationEvent in events do
			if destroyed then
				break
			end
			dispatchEvent(event.kind, event.tagId)
		end
		dispatchDerivedEvents()
	end

	-- Returns the first unavailable application id. Commit must follow without consumer callbacks.
	function controller:_validateApplications(applications: { TagApplication }): string?
		for _, application: TagApplication in applications do
			if destroyed or TagRegistry.Get(application.id) == nil then
				return application.id
			end
			local duration: number? = application.duration
			if duration ~= nil and (not math.isfinite(duration) or duration <= 0) then
				return application.id
			end
		end
		return nil
	end

	controller.OnTagAdded = SignalModule.wrapEvent(tagAddedSignal)
	controller.OnTagRemoved = SignalModule.wrapEvent(tagRemovedSignal)
	controller.OnTagRefreshed = SignalModule.wrapEvent(tagRefreshedSignal)
	controller.OnTagChanged = SignalModule.wrapEvent(tagChangedSignal)
	controller.OnTagExpired = SignalModule.wrapEvent(tagExpiredSignal)

	function controller:_addTagWithReceipt(
		tagId: string,
		options: AddTagOptions?
	): (boolean, string?, TagMutationReceipt?)
		local tagDefinition: TagDefinition? = TagRegistry.Get(tagId)

		if tagDefinition == nil then
			return false, "UnknownTagId:" .. tagId, nil
		end

		if options ~= nil and options.duration ~= nil and options.duration <= 0 then
			return false, "TagDurationMustBePositive", nil
		end

		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]
		local resolvedDuration: number? = TagControllerInstanceUtils.ResolveDuration(tagDefinition, options)

		if tagDefinition.duplicateBehavior == "Ignore" then
			if activeInstances ~= nil and #activeInstances > 0 then
				return true, nil, nil
			end

			local instance: TagInstanceRecord =
				TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
			recordVersions[instance] = 0
			activeTagsById[tagId] = { instance }
			controller._activeTagsById = activeTagsById
			TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			fireEvent("Added", tagId)
			return true, nil, { tagId = tagId, record = instance, version = 0 }
		end

		if tagDefinition.duplicateBehavior == "Refresh" then
			if activeInstances ~= nil and #activeInstances > 0 then
				TagControllerInstanceUtils.RefreshTagInstance(activeInstances[1], resolvedDuration)
				recordVersions[activeInstances[1]] = (recordVersions[activeInstances[1]] or 0) + 1
				TagControllerStepUtils.ReconcileTimedInstance(
					advancingInstancesByController,
					self,
					actor,
					activeInstances[1]
				)
				UpdateHeartbeatConnection()
				local version: number = recordVersions[activeInstances[1]]
				local receipt: TagMutationReceipt =
					{ tagId = tagId, record = activeInstances[1], version = version, previousVersion = version - 1 }
				fireEvent("Refreshed", tagId)
				return true, nil, receipt
			end

			local instance: TagInstanceRecord =
				TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
			recordVersions[instance] = 0
			activeTagsById[tagId] = { instance }
			controller._activeTagsById = activeTagsById
			TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			fireEvent("Added", tagId)
			return true, nil, { tagId = tagId, record = instance, version = 0 }
		end

		local stackInstances: { TagInstanceRecord }? = activeInstances

		if stackInstances == nil then
			activeTagsById[tagId] = {}
			stackInstances = activeTagsById[tagId]
			controller._activeTagsById = activeTagsById
		end

		if stackInstances == nil then
			return false, "TagActiveInstancesInitFailed:" .. tagId, nil
		end

		local maxStacks: number? = tagDefinition.maxStacks
		local isAtMaxStacks: boolean = maxStacks ~= nil and #stackInstances >= maxStacks

		if isAtMaxStacks then
			local refreshTarget: TagInstanceRecord = TagControllerInstanceUtils.SelectStackRefreshTarget(stackInstances)
			TagControllerInstanceUtils.RefreshTagInstance(refreshTarget, resolvedDuration)
			recordVersions[refreshTarget] = (recordVersions[refreshTarget] or 0) + 1
			TagControllerStepUtils.ReconcileTimedInstance(advancingInstancesByController, self, actor, refreshTarget)
			UpdateHeartbeatConnection()
			local version: number = recordVersions[refreshTarget]
			local receipt: TagMutationReceipt =
				{ tagId = tagId, record = refreshTarget, version = version, previousVersion = version - 1 }
			fireEvent("Refreshed", tagId)
			return true, nil, receipt
		end

		local instance: TagInstanceRecord =
			TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
		recordVersions[instance] = 0
		table.insert(stackInstances, instance)
		controller._activeTagsById = activeTagsById
		TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
		UpdateHeartbeatConnection()
		fireEvent("Added", tagId)
		return true, nil, { tagId = tagId, record = instance, version = 0 }
	end

	function controller:AddTag(tagId: string, options: AddTagOptions?): (boolean, string?)
		local added: boolean, reason: string? = self:_addTagWithReceipt(tagId, options)
		return added, reason
	end

	function controller:_removeByReceipt(handle: TagMutationReceipt): ()
		local instances: { TagInstanceRecord }? = activeTagsById[handle.tagId]
		if instances == nil then
			return
		end
		for index: number, record: TagInstanceRecord in instances do
			if record == handle.record and (recordVersions[record] or 0) == handle.version then
				TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
					advancingInstancesByController,
					self,
					record
				)
				if #instances == 1 then
					activeTagsById[handle.tagId] = nil
				else
					table.remove(instances, index)
				end
				UpdateHeartbeatConnection()
				fireEvent("Removed", handle.tagId)
				return
			end
		end
	end

	function controller:RemoveTag(tagId: string): (boolean, string?)
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false, "TagNotActive"
		end

		for _, instance: TagInstanceRecord in activeInstances do
			TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
				advancingInstancesByController,
				self,
				instance
			)
		end
		UpdateHeartbeatConnection()
		activeTagsById[tagId] = nil
		self._activeTagsById = activeTagsById
		fireEvent("Removed", tagId)

		return true, nil
	end

	function controller:RemoveSingleTag(tagId: string): (boolean, string?)
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false, "TagNotActive"
		end

		if #activeInstances == 1 then
			TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
				advancingInstancesByController,
				self,
				activeInstances[1]
			)
			UpdateHeartbeatConnection()
			activeTagsById[tagId] = nil
			self._activeTagsById = activeTagsById
			fireEvent("Removed", tagId)
			return true, nil
		end

		local removeIndex: number = TagControllerInstanceUtils.SelectOldestAppliedInstanceIndex(activeInstances)

		TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
			advancingInstancesByController,
			self,
			activeInstances[removeIndex]
		)
		UpdateHeartbeatConnection()
		table.remove(activeInstances, removeIndex)
		self._activeTagsById = activeTagsById
		fireEvent("Removed", tagId)

		return true, nil
	end

	function controller:HasTag(tagId: string): boolean
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]
		return activeInstances ~= nil and #activeInstances > 0
	end

	function controller:GetActiveTags(): { ActiveTagSnapshot }
		local activeTags: { ActiveTagSortRecord } = {}

		for tagId: string, instances: { TagInstanceRecord } in activeTagsById do
			if #instances > 0 then
				table.insert(activeTags, {
					tagId = tagId,
					stackCount = #instances,
					oldestAppliedOrder = TagControllerInstanceUtils.GetOldestAppliedOrder(instances),
					remainingDuration = TagControllerInstanceUtils.GetLongestRemainingDuration(instances),
				})
			end
		end

		table.sort(activeTags, function(left: ActiveTagSortRecord, right: ActiveTagSortRecord)
			if left.oldestAppliedOrder == right.oldestAppliedOrder then
				return left.tagId < right.tagId
			end

			return left.oldestAppliedOrder < right.oldestAppliedOrder
		end)

		local snapshots: { ActiveTagSnapshot } = {}

		for _, activeTag in activeTags do
			table.insert(snapshots, {
				tagId = activeTag.tagId,
				stackCount = activeTag.stackCount,
				remainingDuration = activeTag.remainingDuration,
			})
		end

		return snapshots
	end

	function controller:GetTagInstances(tagId: string): { TagInstanceSnapshot }
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return {}
		end

		local snapshots: { TagInstanceSnapshot } = {}

		for _, instance: TagInstanceRecord in activeInstances do
			table.insert(snapshots, {
				tagId = instance.tagId,
				duration = instance.duration,
				remainingDuration = instance.remainingDuration,
				appliedOrder = instance.appliedOrder,
			})
		end

		return snapshots
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		table.clear(mutationObservers)
		TagControllerStepUtils.ClearAdvancingInstancesForController(advancingInstancesByController, self)
		UpdateHeartbeatConnection()
		activeTagsById = {}
		self._activeTagsById = activeTagsById
		ownedSignals:Destroy()
	end

	function controller:_expireTimedInstance(tagRecord: TagInstanceRecord): boolean
		if destroyed then
			return false
		end

		local activeInstances: { TagInstanceRecord }?, removeIndex: number? =
			TagControllerInstanceUtils.FindActiveTagInstance(self._activeTagsById, tagRecord)

		if activeInstances == nil or removeIndex == nil then
			return false
		end

		TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
			advancingInstancesByController,
			self,
			tagRecord
		)
		UpdateHeartbeatConnection()

		if #activeInstances == 1 then
			activeTagsById[tagRecord.tagId] = nil
		else
			table.remove(activeInstances, removeIndex)
		end
		self._activeTagsById = activeTagsById

		fireEvent("Expired", tagRecord.tagId)
		return true
	end

	return controller :: TagController
end

function TagController.Step(deltaTime: number)
	if deltaTime <= 0 then
		return
	end

	for controller: TagController, advancingControllerEntry: AdvancingControllerEntry in advancingInstancesByController do
		if not advancingControllerEntry.actor.enabled then
			continue
		end

		local steppedInstances: { TagInstanceRecord } = table.clone(advancingControllerEntry.instances)
		local dueTickRecords: { { tagRecord: TagInstanceRecord, tagDefinition: TagDefinition } } = {}
		local expiredInstances: { TagInstanceRecord } = {}
		local internalController: InternalTagController = controller :: InternalTagController

		for _, tagRecord: TagInstanceRecord in steppedInstances do
			local tagDefinition: TagDefinition? = TagRegistry.Get(tagRecord.tagId)
			local stepResult: StepTagInstanceResult =
				TagControllerStepUtils.StepTagInstance(tagRecord, deltaTime, tagDefinition)

			if stepResult.shouldTick and tagDefinition ~= nil then
				table.insert(dueTickRecords, {
					tagRecord = tagRecord,
					tagDefinition = tagDefinition,
				})
			end

			if stepResult.shouldExpire then
				table.insert(expiredInstances, tagRecord)
			end
		end

		for _, dueTickRecord in dueTickRecords do
			local activeInstances: { TagInstanceRecord }?, recordIndex: number? =
				TagControllerInstanceUtils.FindActiveTagInstance(
					internalController._activeTagsById,
					dueTickRecord.tagRecord
				)

			if activeInstances == nil or recordIndex == nil then
				continue
			end

			TagControllerTickUtils.FireProtectedOnTick(
				dueTickRecord.tagDefinition,
				advancingControllerEntry.actor,
				deltaTime
			)
		end

		for _, tagRecord: TagInstanceRecord in expiredInstances do
			internalController:_expireTimedInstance(tagRecord)
		end
	end
end

function TagController._setAutomaticSteppingEnabledForTests(enabled: boolean)
	automaticSteppingEnabled = enabled
	UpdateHeartbeatConnection()
end

return TagController
