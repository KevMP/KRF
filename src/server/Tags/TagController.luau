--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local TagTypes = require(script.Parent.types)
local TagRegistry = require(script.Parent.TagRegistry)
local TagControllerEventUtils = require(script.Parent.TagControllerEventUtils)
local TagControllerInstanceUtils = require(script.Parent.TagControllerInstanceUtils)

export type TagController = TagTypes.TagController
export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition

type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type TagInstanceFactoryContext = TagControllerInstanceUtils.TagInstanceFactoryContext
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot
type ActiveTagSortRecord = {
	tagId: string,
	stackCount: number,
	oldestAppliedOrder: number,
}

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

local TagController = {}

function TagController.new(actor: ActorTypes.Actor): TagController
	local tagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local tagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()

	local activeTagsById: { [string]: { TagInstanceRecord } } = {}
	local nextAppliedOrder: number = 0
	local destroyed: boolean = false

	local factoryContext: TagInstanceFactoryContext = {
		nextAppliedOrder = nextAppliedOrder,
	}

	local eventContext = {
		actor = actor,
		tagAddedSignal = tagAddedSignal,
		tagRemovedSignal = tagRemovedSignal,
		tagRefreshedSignal = tagRefreshedSignal,
		tagChangedSignal = tagChangedSignal,
	}

	local self = {
		OnTagAdded = SignalModule.wrapEvent(tagAddedSignal),
		OnTagRemoved = SignalModule.wrapEvent(tagRemovedSignal),
		OnTagRefreshed = SignalModule.wrapEvent(tagRefreshedSignal),
		OnTagChanged = SignalModule.wrapEvent(tagChangedSignal),
	}

	function self.AddTag(_self, tagId: string, options: AddTagOptions?): (boolean, string?)
		local tagDefinition: TagDefinition? = TagRegistry.Get(tagId)

		if tagDefinition == nil then
			return false, "UnknownTagId:" .. tagId
		end

		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]
		local resolvedDuration: number? = TagControllerInstanceUtils.ResolveDuration(tagDefinition, options)

		if tagDefinition.duplicateBehavior == "Ignore" then
			if activeInstances ~= nil and #activeInstances > 0 then
				return true, nil
			end

			activeTagsById[tagId] =
				{ TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration) }
			TagControllerEventUtils.FireTagAdded(eventContext, tagId)
			return true, nil
		end

		if tagDefinition.duplicateBehavior == "Refresh" then
			if activeInstances ~= nil and #activeInstances > 0 then
				TagControllerInstanceUtils.RefreshTagInstance(activeInstances[1], resolvedDuration)
				TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
				return true, nil
			end

			activeTagsById[tagId] =
				{ TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration) }
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
			TagControllerEventUtils.FireTagRefreshed(eventContext, tagId)
			return true, nil
		end

		table.insert(
			stackInstances,
			TagControllerInstanceUtils.CreateTagInstance(factoryContext, tagId, resolvedDuration)
		)
		TagControllerEventUtils.FireTagAdded(eventContext, tagId)

		return true, nil
	end

	function self.RemoveTag(_self, tagId: string): (boolean, string?)
		local activeInstances: { TagInstanceRecord }? = activeTagsById[tagId]

		if activeInstances == nil or #activeInstances == 0 then
			return false, "TagNotActive"
		end

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
			activeTagsById[tagId] = nil
			TagControllerEventUtils.FireTagRemoved(eventContext, tagId)
			return true, nil
		end

		local removeIndex: number = TagControllerInstanceUtils.SelectOldestAppliedInstanceIndex(activeInstances)
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
		activeTagsById = {}
	end

	return self :: TagController
end

return TagController
