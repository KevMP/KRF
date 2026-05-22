--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local TagTypes = require(script.Parent.types)
local TagRegistry = require(script.Parent.TagRegistry)
local TagControllerEventUtils = require(script.Parent.utils.TagControllerEvent)
local TagControllerInstanceUtils = require(script.Parent.utils.TagControllerInstance)
local TagControllerStepUtils = require(script.Parent.utils.TagControllerStepUtils)

local RunService: RunService = game:GetService("RunService")

export type TagController = TagTypes.TagController
export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition

type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type TagInstanceFactoryContext = TagControllerInstanceUtils.TagInstanceFactoryContext
type TagControllerEventContext = TagControllerEventUtils.TagControllerEventContext
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot
type TimedControllerEntry = TagControllerStepUtils.TimedControllerEntry
type InternalTagController = TagController & {
	_expireTimedInstance: (self: InternalTagController, tagRecord: TagInstanceRecord) -> boolean,
}
type ActiveTagSortRecord = {
	tagId: string,
	stackCount: number,
	oldestAppliedOrder: number,
	remainingDuration: number?,
}
type ActiveTagsById = { [string]: { TagInstanceRecord } }
type TagControllerModule = {
	new: (actor: ActorTypes.Actor) -> TagController,
	Step: (deltaTime: number) -> (),
	_setAutomaticSteppingEnabledForTests: (enabled: boolean) -> (),
}

local TagController: TagControllerModule = {} :: TagControllerModule
local HeartBeatConnection: RBXScriptConnection? = nil
local automaticSteppingEnabled: boolean = true

local timedInstancesByController: { [TagController]: TimedControllerEntry } = {}

local function UpdateHeartbeatConnection(): ()
	local hasTimedControllers: boolean = next(timedInstancesByController) ~= nil

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

local function GetOldestAppliedOrder(instances: { TagInstanceRecord }): number
	local oldestAppliedOrder: number = instances[1].appliedOrder

	for index: number = 2, #instances do
		local instance: TagInstanceRecord = instances[index]

		if instance.appliedOrder < oldestAppliedOrder then
			oldestAppliedOrder = instance.appliedOrder
		end
	end

	return oldestAppliedOrder
end

function TagController.new(actor: ActorTypes.Actor): TagController
	local tagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagExpiredSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()

	local activeTagsById: ActiveTagsById = {}
	local destroyed: boolean = false

	local factoryContext: TagInstanceFactoryContext = {
		nextAppliedOrder = 0,
	}

	local eventContext: TagControllerEventContext = {
		actor = actor,
		tagAddedSignal = tagAddedSignal,
		tagRemovedSignal = tagRemovedSignal,
		tagRefreshedSignal = tagRefreshedSignal,
		tagChangedSignal = tagChangedSignal,
		tagExpiredSignal = tagExpiredSignal,
	}

	local self: InternalTagController = {} :: InternalTagController

	self.OnTagAdded = SignalModule.wrapEvent(tagAddedSignal)
	self.OnTagRemoved = SignalModule.wrapEvent(tagRemovedSignal)
	self.OnTagRefreshed = SignalModule.wrapEvent(tagRefreshedSignal)
	self.OnTagChanged = SignalModule.wrapEvent(tagChangedSignal)
	self.OnTagExpired = SignalModule.wrapEvent(tagExpiredSignal)

	function self.AddTag(_self, tagId: string, options: AddTagOptions?): (boolean, string?)
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
			TagControllerStepUtils.TryAddTimedInstance(timedInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
			return true, nil
		end

		if tagDefinition.duplicateBehavior == "Refresh" then
			if activeInstances ~= nil and #activeInstances > 0 then
				TagControllerInstanceUtils.RefreshTagInstance(activeInstances[1], resolvedDuration)
				TagControllerStepUtils.ReconcileTimedInstance(
					timedInstancesByController,
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
			TagControllerStepUtils.TryAddTimedInstance(timedInstancesByController, self, actor, instance)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
			return true, nil
		end

		local stackInstances: { TagInstanceRecord }? = activeInstances

		if stackInstances == nil then
			activeTagsById[tagId] = {}
			stackInstances = activeTagsById[tagId]
		end

		if stackInstances == nil then
			return false, "TagActiveInstancesInitFailed:" .. tagId
		end

		local maxStacks: number? = tagDefinition.maxStacks
		local isAtMaxStacks: boolean = maxStacks ~= nil and #stackInstances >= maxStacks

		if isAtMaxStacks then
			local refreshTarget: TagInstanceRecord = TagControllerInstanceUtils.SelectStackRefreshTarget(stackInstances)
			TagControllerInstanceUtils.RefreshTagInstance(refreshTarget, resolvedDuration)
			TagControllerStepUtils.ReconcileTimedInstance(timedInstancesByController, self, actor, refreshTarget)
			UpdateHeartbeatConnection()
			TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
			return true, nil
		end

		local instance: TagInstanceRecord =
			TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
		table.insert(stackInstances, instance)
		TagControllerStepUtils.TryAddTimedInstance(timedInstancesByController, self, actor, instance)
		UpdateHeartbeatConnection()
		TagControllerEventUtils.FireTagAdded(eventContext, tagId)
		return true, nil
	end

	function self.RemoveTag(_self, tagId: string): (boolean, string?)
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false, "TagNotActive"
		end

		for _, instance: TagInstanceRecord in activeInstances do
			TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(timedInstancesByController, self, instance)
		end
		UpdateHeartbeatConnection()
		activeTagsById[tagId] = nil
		TagControllerEventUtils.FireTagRemoved(eventContext, tagId)

		return true, nil
	end

	function self.RemoveSingleTag(_self, tagId: string): (boolean, string?)
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false, "TagNotActive"
		end

		if #activeInstances == 1 then
			TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(
				timedInstancesByController,
				self,
				activeInstances[1]
			)
			UpdateHeartbeatConnection()
			activeTagsById[tagId] = nil
			TagControllerEventUtils.FireTagRemoved(eventContext, tagId)
			return true, nil
		end

		local removeIndex: number = TagControllerInstanceUtils.SelectOldestAppliedInstanceIndex(activeInstances)

		TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(
			timedInstancesByController,
			self,
			activeInstances[removeIndex]
		)
		UpdateHeartbeatConnection()
		table.remove(activeInstances, removeIndex)
		TagControllerEventUtils.FireTagRemoved(eventContext, tagId)

		return true, nil
	end

	function self.HasTag(_self, tagId: string): boolean
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]
		return activeInstances ~= nil and #activeInstances > 0
	end

	function self.GetActiveTags(_self): { ActiveTagSnapshot }
		local activeTags: { ActiveTagSortRecord } = {}

		for tagId: string, instances: { TagInstanceRecord } in activeTagsById do
			if #instances > 0 then
				table.insert(activeTags, {
					tagId = tagId,
					stackCount = #instances,
					oldestAppliedOrder = GetOldestAppliedOrder(instances),
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

	function self.GetTagInstances(_self, tagId: string): { TagInstanceSnapshot }
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

	function self.Destroy(_self): ()
		if destroyed then
			return
		end

		destroyed = true
		TagControllerStepUtils.ClearTimedInstancesForController(timedInstancesByController, self)
		UpdateHeartbeatConnection()
		activeTagsById = {}
	end

	function self._expireTimedInstance(_self, tagRecord: TagInstanceRecord): boolean
		if destroyed then
			return false
		end

		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagRecord.tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false
		end

		local removeIndex: number? = table.find(activeInstances, tagRecord)

		if removeIndex == nil then
			return false
		end

		TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(timedInstancesByController, self, tagRecord)
		UpdateHeartbeatConnection()

		if #activeInstances == 1 then
			activeTagsById[tagRecord.tagId] = nil
		else
			table.remove(activeInstances, removeIndex)
		end

		TagControllerEventUtils.FireTagExpired(eventContext, tagRecord.tagId)
		return true
	end

	return self :: TagController
end

function TagController.Step(deltaTime: number)
	if deltaTime <= 0 then
		return
	end

	for controller: TagController, timedControllerEntry: TimedControllerEntry in timedInstancesByController do
		if not timedControllerEntry.actor.enabled then
			continue
		end

		local steppedInstances: { TagInstanceRecord } = table.clone(timedControllerEntry.instances)
		local expiredInstances: { TagInstanceRecord } = {}

		for _, tagRecord: TagInstanceRecord in steppedInstances do
			local expired: boolean = TagControllerStepUtils.StepTagInstance(tagRecord, deltaTime)

			if expired then
				table.insert(expiredInstances, tagRecord)
			end
		end

		local internalController: InternalTagController = controller :: InternalTagController

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
