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

export type TagController = TagTypes.TagController
export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition

type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type TagInstanceFactoryContext = TagControllerInstanceUtils.TagInstanceFactoryContext
type ActiveTagsById = TagControllerInstanceUtils.ActiveTagsById
type TagControllerEventContext = TagControllerEventUtils.TagControllerEventContext
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot
type AdvancingControllerEntry = TagControllerStepUtils.AdvancingControllerEntry
type StepTagInstanceResult = TagControllerStepUtils.StepTagInstanceResult
type InternalTagController = TagController & {
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

local advancingInstancesByController: { [TagController]: AdvancingControllerEntry } = {}

local function UpdateHeartbeatConnection(): ()
	local hasTimedControllers: boolean = next(advancingInstancesByController) ~= nil

	if automaticSteppingEnabled and hasTimedControllers then
		if HeartBeatConnection == nil then
			HeartBeatConnection = RunService.Heartbeat:Connect(TagController.Step)
		end

		return
	end

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

	controller.OnTagAdded = SignalModule.wrapEvent(tagAddedSignal)
	controller.OnTagRemoved = SignalModule.wrapEvent(tagRemovedSignal)
	controller.OnTagRefreshed = SignalModule.wrapEvent(tagRefreshedSignal)
	controller.OnTagChanged = SignalModule.wrapEvent(tagChangedSignal)
	controller.OnTagExpired = SignalModule.wrapEvent(tagExpiredSignal)

	function controller:AddTag(tagId: string, options: AddTagOptions?): (boolean, string?)
		local tagDefinition: TagDefinition? = TagRegistry.Get(tagId)

		if tagDefinition == nil then
			return false, "UnknownTagId:" .. tagId
		end

		if options ~= nil and options.duration ~= nil and options.duration <= 0 then
			return false, "TagDurationMustBePositive"
		end

		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]
		local resolvedDuration: number? = TagControllerInstanceUtils.ResolveDuration(tagDefinition, options)

		if tagDefinition.duplicateBehavior == "Ignore" then
			if activeInstances ~= nil and #activeInstances > 0 then
				return true, nil
			end

			local instance: TagInstanceRecord =
				TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
			activeTagsById[tagId] = { instance }
			self._activeTagsById = activeTagsById
			TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
			return true, nil
		end

		if tagDefinition.duplicateBehavior == "Refresh" then
			if activeInstances ~= nil and #activeInstances > 0 then
				TagControllerInstanceUtils.RefreshTagInstance(activeInstances[1], resolvedDuration)
				TagControllerStepUtils.ReconcileTimedInstance(
					advancingInstancesByController,
					self,
					actor,
					activeInstances[1]
				)
				UpdateHeartbeatConnection()
				TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
				return true, nil
			end

			local instance: TagInstanceRecord =
				TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
			activeTagsById[tagId] = { instance }
			self._activeTagsById = activeTagsById
			TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
			return true, nil
		end

		local stackInstances: { TagInstanceRecord }? = activeInstances

		if stackInstances == nil then
			activeTagsById[tagId] = {}
			stackInstances = activeTagsById[tagId]
			self._activeTagsById = activeTagsById
		end

		if stackInstances == nil then
			return false, "TagActiveInstancesInitFailed:" .. tagId
		end

		local maxStacks: number? = tagDefinition.maxStacks
		local isAtMaxStacks: boolean = maxStacks ~= nil and #stackInstances >= maxStacks

		if isAtMaxStacks then
			local refreshTarget: TagInstanceRecord = TagControllerInstanceUtils.SelectStackRefreshTarget(stackInstances)
			TagControllerInstanceUtils.RefreshTagInstance(refreshTarget, resolvedDuration)
			TagControllerStepUtils.ReconcileTimedInstance(advancingInstancesByController, self, actor, refreshTarget)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
			return true, nil
		end

		local instance: TagInstanceRecord =
			TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
		table.insert(stackInstances, instance)
		self._activeTagsById = activeTagsById
		TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, self, actor, instance)
		UpdateHeartbeatConnection()
		TagControllerEventUtils.FireTagAdded(eventContext, tagId)
		return true, nil
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
		TagControllerEventUtils.FireTagRemoved(eventContext, tagId)

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
			TagControllerEventUtils.FireTagRemoved(eventContext, tagId)
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
		TagControllerEventUtils.FireTagRemoved(eventContext, tagId)

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

		TagControllerEventUtils.FireTagExpired(eventContext, tagRecord.tagId)
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
