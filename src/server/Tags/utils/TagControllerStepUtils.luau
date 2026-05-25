local TagTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local TagControllerInstanceUtils = require(script.Parent.Parent.utils.TagControllerInstance)

type TagController = TagTypes.TagController
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type TagDefinition = TagTypes.TagDefinition
type Actor = ActorTypes.Actor

export type AdvancingControllerEntry = {
	instances: { TagInstanceRecord },
	actor: Actor,
}

export type StepTagInstanceResult = {
	shouldTick: boolean,
	shouldExpire: boolean,
}

local TagControllerStepUtils = {}

local function NeedsAdvancement(record: TagInstanceRecord): boolean
	return record.remainingDuration ~= nil or record.remainingToNextTick ~= nil
end

local function AdvanceTicking(tagRecord: TagInstanceRecord, deltaTime: number, tagDefinition: TagDefinition?): boolean
	local remainingToNextTick: number? = tagRecord.remainingToNextTick

	if remainingToNextTick == nil then
		return false
	end

	local nextRemainingToNextTick: number = remainingToNextTick - deltaTime
	tagRecord.remainingToNextTick = nextRemainingToNextTick

	if nextRemainingToNextTick > 0 then
		return false
	end

	if tagDefinition ~= nil and tagDefinition.tickInterval ~= nil then
		tagRecord.remainingToNextTick = tagDefinition.tickInterval
	end

	return true
end

local function AdvanceDuration(tagRecord: TagInstanceRecord, deltaTime: number): boolean
	local remainingDuration: number? = tagRecord.remainingDuration

	if remainingDuration == nil then
		return false
	end

	local nextRemainingDuration: number = remainingDuration - deltaTime
	tagRecord.remainingDuration = nextRemainingDuration

	return nextRemainingDuration <= 0
end

TagControllerStepUtils.SetAdvancingInstanceByControllerRecord = function(
	advancingInstancesByController: {
		[TagController]: AdvancingControllerEntry,
	},
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not advancingInstancesByController[controller] then
		advancingInstancesByController[controller] = {
			instances = {},
			actor = actor,
		}
	else
		advancingInstancesByController[controller].actor = actor
	end

	if not table.find(advancingInstancesByController[controller].instances, record) then
		table.insert(advancingInstancesByController[controller].instances, record)
	end
end

TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord = function(
	advancingInstancesByController: {
		[TagController]: AdvancingControllerEntry,
	},
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not advancingInstancesByController[controller] then
		return
	end

	local recordIndex: number? = table.find(advancingInstancesByController[controller].instances, record)

	if recordIndex then
		table.remove(advancingInstancesByController[controller].instances, recordIndex)
	end

	if #advancingInstancesByController[controller].instances == 0 then
		advancingInstancesByController[controller] = nil
	end
end

TagControllerStepUtils.ClearAdvancingInstancesForController = function(
	advancingInstancesByController: {
		[TagController]: AdvancingControllerEntry,
	},
	controller: TagController
): ()
	advancingInstancesByController[controller] = nil
end

TagControllerStepUtils.TryAddAdvancingInstance = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not NeedsAdvancement(record) then
		return
	end

	TagControllerStepUtils.SetAdvancingInstanceByControllerRecord(
		advancingInstancesByController,
		controller,
		actor,
		record
	)
end

TagControllerStepUtils.ReconcileTimedInstance = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not NeedsAdvancement(record) then
		TagControllerStepUtils.RemoveAdvancingInstanceByControllerRecord(
			advancingInstancesByController,
			controller,
			record
		)
	else
		TagControllerStepUtils.TryAddAdvancingInstance(advancingInstancesByController, controller, actor, record)
	end
end

TagControllerStepUtils.StepTagInstance = function(
	tagRecord: TagInstanceRecord,
	deltaTime: number,
	tagDefinition: TagDefinition?
): StepTagInstanceResult
	return {
		shouldTick = AdvanceTicking(tagRecord, deltaTime, tagDefinition),
		shouldExpire = AdvanceDuration(tagRecord, deltaTime),
	}
end

return TagControllerStepUtils
