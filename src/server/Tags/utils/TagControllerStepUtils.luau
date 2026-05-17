local TagTypes = require(script.Parent.Parent.types)
local TagControllerInstanceUtils = require(script.Parent.Parent.utils.TagControllerInstance)

type TagController = TagTypes.TagController
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord

local TagControllerStepUtils = {}

TagControllerStepUtils.SetTimedInstanceByControllerRecord = function(
	timedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not timedInstancesByController[controller] then
		timedInstancesByController[controller] = {}
	end

	if not table.find(timedInstancesByController[controller], record) then
		table.insert(timedInstancesByController[controller], record)
	end
end

TagControllerStepUtils.RemoveTimedInstanceByControllerRecord = function(
	timedInstancesByController: { [TagController]: { TagInstanceRecord } },
	controller: TagController,
	record: TagInstanceRecord
): ()
	if not timedInstancesByController[controller] then
		return
	end

	local recordIndex: number? = table.find(timedInstancesByController[controller], record)

	if recordIndex then
		table.remove(timedInstancesByController[controller], recordIndex)
	end

	if #timedInstancesByController[controller] == 0 then
		timedInstancesByController[controller] = nil
	end
end

TagControllerStepUtils.ClearTimedInstancesForController = function(
	timedInstancesByController: {
		[TagController]: { TagInstanceRecord },
	},
	controller: TagController
): ()
	timedInstancesByController[controller] = nil
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
