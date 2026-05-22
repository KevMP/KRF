local TagTypes = require(script.Parent.Parent.types)
local TagControllerInstanceUtils = require(script.Parent.Parent.utils.TagControllerInstance)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

type TagController = TagTypes.TagController
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type Actor = ActorTypes.Actor

export type TimedControllerEntry = {
	instances: { TagInstanceRecord },
	actor: Actor,
}

local TagControllerStepUtils = {}

TagControllerStepUtils.SetTimedInstanceByControllerRecord = function(
	timedInstancesByController: { [TagController]: TimedControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not timedInstancesByController[controller] then
		timedInstancesByController[controller] = {
			instances = {},
			actor = actor,
		}
	else
		timedInstancesByController[controller].actor = actor
	end

	if not table.find(timedInstancesByController[controller].instances, record) then
		table.insert(timedInstancesByController[controller].instances, record)
	end
end

TagControllerStepUtils.RemoveTimedInstanceByControllerRecord = function(
	timedInstancesByController: { [TagController]: TimedControllerEntry },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not timedInstancesByController[controller] then
		return
	end

	local recordIndex: number? = table.find(timedInstancesByController[controller].instances, record)

	if recordIndex then
		table.remove(timedInstancesByController[controller].instances, recordIndex)
	end

	if #timedInstancesByController[controller].instances == 0 then
		timedInstancesByController[controller] = nil
	end
end

TagControllerStepUtils.ClearTimedInstancesForController = function(
	timedInstancesByController: {
		[TagController]: TimedControllerEntry,
	},
	controller: TagController
): ()
	timedInstancesByController[controller] = nil
end

TagControllerStepUtils.TryAddTimedInstance = function(
	timedInstancesByController: { [TagController]: TimedControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if record.remainingDuration == nil then
		return
	end

	TagControllerStepUtils.SetTimedInstanceByControllerRecord(timedInstancesByController, controller, actor, record)
end

TagControllerStepUtils.ReconcileTimedInstance = function(
	timedInstancesByController: { [TagController]: TimedControllerEntry },
	controller: TagController,
	actor: Actor,
	record: TagInstanceRecord
): ()
	if not record.remainingDuration then
		TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(timedInstancesByController, controller, record)
	else
		TagControllerStepUtils.TryAddTimedInstance(timedInstancesByController, controller, actor, record)
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
