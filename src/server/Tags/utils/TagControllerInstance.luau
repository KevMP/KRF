--!strict
local TagTypes = require(script.Parent.Parent.types)

export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition
export type TagInstanceRecord = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	remainingToNextTick: number?,
	appliedOrder: number,
}

export type TagInstanceFactoryContext = {
	nextAppliedOrder: number,
}
export type ActiveTagsById = {
	[string]: { TagInstanceRecord },
}

type TagRegistry = TagTypes.TagRegistry

local TagCatalogue: TagRegistry = require(script.Parent.Parent.TagRegistry)

local TagControllerInstanceUtils = {}

function TagControllerInstanceUtils.ResolveDuration(tagDefinition: TagDefinition, options: AddTagOptions?): number?
	if options ~= nil and options.duration ~= nil then
		return options.duration
	end

	if tagDefinition.defaultDuration ~= nil then
		return tagDefinition.defaultDuration
	end

	return nil
end

function TagControllerInstanceUtils.CreateTagInstance(
	context: TagInstanceFactoryContext,
	tagId: string,
	duration: number?
): TagInstanceRecord
	local tagDefinition: TagDefinition? = TagCatalogue.Get(tagId)

	local instance: TagInstanceRecord = {
		tagId = tagId,
		duration = duration,
		remainingDuration = duration,
		appliedOrder = context.nextAppliedOrder,
	}

	if tagDefinition and tagDefinition.tickInterval then
		instance.remainingToNextTick = tagDefinition.tickInterval
	end

	context.nextAppliedOrder += 1

	return instance
end

function TagControllerInstanceUtils.RefreshTagInstance(instance: TagInstanceRecord, duration: number?): ()
	instance.duration = duration
	instance.remainingDuration = duration
end

local function GetLowestComparableRemainingDuration(instance: TagInstanceRecord): number
	if instance.remainingDuration == nil then
		return math.huge
	end

	return instance.remainingDuration
end

function TagControllerInstanceUtils.GetLongestRemainingDuration(instances: { TagInstanceRecord }): number?
	local longestRemainingDuration: number? = nil

	for _, instance: TagInstanceRecord in instances do
		local remainingDuration: number? = instance.remainingDuration

		if remainingDuration ~= nil then
			if longestRemainingDuration == nil or remainingDuration > longestRemainingDuration then
				longestRemainingDuration = remainingDuration
			end
		end
	end

	return longestRemainingDuration
end

function TagControllerInstanceUtils.SelectStackRefreshTarget(instances: { TagInstanceRecord }): TagInstanceRecord
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

function TagControllerInstanceUtils.SelectOldestAppliedInstanceIndex(instances: { TagInstanceRecord }): number
	local selectedIndex: number = 1
	local selectedInstance: TagInstanceRecord = instances[selectedIndex]

	for index: number = 2, #instances do
		local candidateInstance: TagInstanceRecord = instances[index]

		if candidateInstance.appliedOrder < selectedInstance.appliedOrder then
			selectedIndex = index
			selectedInstance = candidateInstance
		end
	end

	return selectedIndex
end

function TagControllerInstanceUtils.GetOldestAppliedOrder(instances: { TagInstanceRecord }): number
	local oldestAppliedOrder: number = instances[1].appliedOrder

	for index: number = 2, #instances do
		local instance: TagInstanceRecord = instances[index]

		if instance.appliedOrder < oldestAppliedOrder then
			oldestAppliedOrder = instance.appliedOrder
		end
	end

	return oldestAppliedOrder
end

function TagControllerInstanceUtils.FindActiveTagInstance(
	activeTagsById: ActiveTagsById,
	tagRecord: TagInstanceRecord
): ({ TagInstanceRecord }?, number?)
	local activeInstances: { TagInstanceRecord }? = activeTagsById[tagRecord.tagId]

	if activeInstances == nil or #activeInstances == 0 then
		return nil, nil
	end

	local recordIndex: number? = table.find(activeInstances, tagRecord)

	if recordIndex == nil then
		return nil, nil
	end

	return activeInstances, recordIndex
end

return TagControllerInstanceUtils
