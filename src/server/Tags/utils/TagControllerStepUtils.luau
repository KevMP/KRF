local TagTypes = require(script.Parent.Parent.types)
local TagControllerInstanceUtils = require(script.Parent.Parent.utils.TagControllerInstance)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

type TagController = TagTypes.TagController
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type Actor = ActorTypes.Actor

export type AdvancingControllerEntry = {
	instances: { TagInstanceRecord },
	actor: Actor,
}

local TagControllerStepUtils = {}

TagControllerStepUtils.SetTimedInstanceByControllerRecord = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
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

TagControllerStepUtils.RemoveTimedInstanceByControllerRecord = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
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

TagControllerStepUtils.ClearTimedInstancesForController = function(
	advancingInstancesByController: {
		[TagController]: AdvancingControllerEntry,
	},
	controller: TagController
): ()
	advancingInstancesByController[controller] = nil
end

TagControllerStepUtils.TryAddTimedInstance = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if record.remainingDuration == nil then
		return
	end

	TagControllerStepUtils.SetTimedInstanceByControllerRecord(advancingInstancesByController, controller, actor, record)
end

TagControllerStepUtils.ReconcileTimedInstance = function(
	advancingInstancesByController: { [TagController]: AdvancingControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not record.remainingDuration then
		TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(advancingInstancesByController, controller, record)
	else
		TagControllerStepUtils.TryAddTimedInstance(advancingInstancesByController, controller, actor, record)
	end
end

TagControllerStepUtils.StepTagInstance = function(tagRecord: TagInstanceRecord, deltaTime: number): boolean
	local remainingDuration: number? = tagRecord.remainingDuration

	if remainingDuration == nil then
		return false
	end

	local nextRemainingDuration: number = remainingDuration - deltaTime
	tagRecord.remainingDuration = nextRemainingDuration

	return nextRemainingDuration <= 0
end

return TagControllerStepUtils
