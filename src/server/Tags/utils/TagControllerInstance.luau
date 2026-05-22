--!strict
local TagTypes = require(script.Parent.Parent.types)

export type AddTagOptions = TagTypes.AddTagOptions
export type TagDefinition = TagTypes.TagDefinition
export type TagInstanceRecord = {
	tagId: string,
	duration: number?,
	remainingDuration: number?,
	appliedOrder: number,
}

export type TagInstanceFactoryContext = {
	nextAppliedOrder: number,
}

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
	local instance: TagInstanceRecord = {
		tagId = tagId,
		duration = duration,
		remainingDuration = duration,
		appliedOrder = context.nextAppliedOrder,
	}

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

return TagControllerInstanceUtils
