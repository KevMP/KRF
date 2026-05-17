local TagTypes = require(script.Parent.Parent.types)
local TagControllerInstanceUtils = require(script.Parent.Parent.utils.TagControllerInstance)

type TagController = TagTypes.TagController
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord

local TagControllerStepUtils = {}

TagControllerStepUtils.SetTimedInstanceByControllerRecord = function(
	TimedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not TimedInstancesByController[controller] then
		TimedInstancesByController[controller] = {}
	end

	if not table.find(TimedInstancesByController[controller], record) then
		table.insert(TimedInstancesByController[controller], record)
	end
end

TagControllerStepUtils.RemoveTimedInstanceByControllerRecord = function(
	TimedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not TimedInstancesByController[controller] then
		return
	end

	local recordIndex: number? = table.find(TimedInstancesByController[controller], record)

	if recordIndex then
		table.remove(TimedInstancesByController[controller], recordIndex)
	end
end

TagControllerStepUtils.TryAddTimedInstance = function(
	timedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if record.remainingDuration == nil then
		return
	end

	TagControllerStepUtils.SetTimedInstanceByControllerRecord(timedInstancesByController, controller, record)
end

TagControllerStepUtils.ReconcileTimedInstance = function(
	timedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not record.remainingDuration then
		TagControllerStepUtils.RemoveTimedInstanceByControllerRecord(timedInstancesByController, controller, record)
	else
		TagControllerStepUtils.TryAddTimedInstance(timedInstancesByController, controller, record)
	end
end
return TagControllerStepUtils
