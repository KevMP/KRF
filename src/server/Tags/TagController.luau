--!strict
local serverFolder = script.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local SignalTypes = require(SignalFolder.types)
local SignalModule = require(SignalFolder.SignalModule)
local TagTypes = require(script.Parent.types)
local TagRegistry = require(script.Parent.TagRegistry)

export type TagController = TagTypes.TagController
export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition

type TagInstanceRecord = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	appliedOrder: number,
}

type TagControllerInternal = TagController & {
	_actor: ActorTypes.Actor,
	_destroyed: boolean,

	_activeTagsById: { [string]: { TagInstanceRecord } },
	_nextAppliedOrder: number,

	TagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	TagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	TagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
	TagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string>,
}

local TagController = {}
TagController.__index = TagController

local function ResolveDuration(tagDefinition: TagTypes.TagDefinition, options: AddTagOptions?): number?
	if options ~= nil and options.duration ~= nil then
		return options.duration
	end

	if tagDefinition.defaultDuration ~= nil then
		return tagDefinition.defaultDuration
	end

	return nil
end

local function CreateTagInstance(self: TagControllerInternal, tagId: string, duration: number?): TagInstanceRecord
	local instance: TagInstanceRecord = {
		tagId = tagId,
		duration = duration,
		remainingDuration = duration,
		appliedOrder = self._nextAppliedOrder,
	}

	self._nextAppliedOrder += 1

	return instance
end

local function RefreshTagInstance(instance: TagInstanceRecord, duration: number?): ()
	instance.duration = duration
	instance.remainingDuration = duration
end

local function GetLowestComparableRemainingDuration(instance: TagInstanceRecord): number
	if instance.remainingDuration == nil then
		return math.huge
	end

	return instance.remainingDuration
end

local function SelectStackRefreshTarget(instances: { TagInstanceRecord }): TagInstanceRecord
	local selectedInstance: TagInstanceRecord = instances[1]

	for index: number = 2, #instances do
		local candidateInstance: TagInstanceRecord = instances[index]
		local candidateRemainingDuration: number = GetLowestComparableRemainingDuration(candidateInstance)
		local selectedRemainingDuration: number = GetLowestComparableRemainingDuration(selectedInstance)

		if candidateRemainingDuration < selectedRemainingDuration then
			selectedInstance = candidateInstance
		elseif candidateRemainingDuration == selectedRemainingDuration then
			if candidateInstance.appliedOrder < selectedInstance.appliedOrder then
				selectedInstance = candidateInstance
			end
		end
	end

	return selectedInstance
end

local function FireTagAdded(self: TagControllerInternal, tagId: string): ()
	self.TagAddedSignal:Fire(self._actor, tagId)
	self.TagChangedSignal:Fire(self._actor, tagId)
end

local function FireTagRefreshed(self: TagControllerInternal, tagId: string): ()
	self.TagRefreshedSignal:Fire(self._actor, tagId)
	self.TagChangedSignal:Fire(self._actor, tagId)
end

function TagController.new(actor: ActorTypes.Actor): TagController
	local TagAddedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local TagRemovedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local TagRefreshedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()
	local TagChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string> = SignalModule.new()

	local self: TagControllerInternal = setmetatable({
		OnTagAdded = SignalModule.wrapEvent(TagAddedSignal),
		OnTagRemoved = SignalModule.wrapEvent(TagRemovedSignal),
		OnTagRefreshed = SignalModule.wrapEvent(TagRefreshedSignal),
		OnTagChanged = SignalModule.wrapEvent(TagChangedSignal),

		_actor = actor,
		_destroyed = false,

		_activeTagsById = {},
		_nextAppliedOrder = 0,

		TagAddedSignal = TagAddedSignal,
		TagRemovedSignal = TagRemovedSignal,
		TagRefreshedSignal = TagRefreshedSignal,
		TagChangedSignal = TagChangedSignal,
	}, TagController) :: any

	return self
end

function TagController.AddTag(self: TagControllerInternal, tagId: string, options: AddTagOptions?): (boolean, string?)
	local tagDefinition: TagDefinition? = TagRegistry.Get(tagId)

	if tagDefinition == nil then
		return false, "UnknownTagId:" .. tagId
	end

	local activeInstances: { TagInstanceRecord }? = self._activeTagsById[tagId]
	local resolvedDuration: number? = ResolveDuration(tagDefinition, options)

	if tagDefinition.duplicateBehavior == "Ignore" then
		local existingInstances: { TagInstanceRecord }? = activeInstances

		if existingInstances ~= nil and #existingInstances > 0 then
			return true, nil
		end

		local createdInstances: { TagInstanceRecord } = { CreateTagInstance(self, tagId, resolvedDuration) }
		self._activeTagsById[tagId] = createdInstances
		FireTagAdded(self, tagId)
		return true, nil
	end

	if tagDefinition.duplicateBehavior == "Refresh" then
		local existingInstances: { TagInstanceRecord }? = activeInstances

		if existingInstances ~= nil and #existingInstances > 0 then
			RefreshTagInstance(existingInstances[1], resolvedDuration)
			FireTagRefreshed(self, tagId)
			return true, nil
		end

		local createdInstances: { TagInstanceRecord } = { CreateTagInstance(self, tagId, resolvedDuration) }
		self._activeTagsById[tagId] = createdInstances
		FireTagAdded(self, tagId)
		return true, nil
	end

	local stackInstances: { TagInstanceRecord }? = activeInstances

	if stackInstances == nil then
		self._activeTagsById[tagId] = {}
		stackInstances = self._activeTagsById[tagId]
	end

	if stackInstances == nil then
		return false, "TagActiveInstancesInitFailed:" .. tagId
	end

	local ensuredStackInstances: { TagInstanceRecord } = stackInstances

	local maxStacks: number? = tagDefinition.maxStacks
	local isAtMaxStacks: boolean = maxStacks ~= nil and #ensuredStackInstances >= maxStacks

	if isAtMaxStacks then
		local refreshTarget: TagInstanceRecord = SelectStackRefreshTarget(ensuredStackInstances)
		RefreshTagInstance(refreshTarget, resolvedDuration)
		FireTagRefreshed(self, tagId)
		return true, nil
	end

	table.insert(ensuredStackInstances, CreateTagInstance(self, tagId, resolvedDuration))
	FireTagAdded(self, tagId)

	return true, nil
end

function TagController.Destroy(self: TagControllerInternal): ()
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._activeTagsById = {}
end

return TagController
