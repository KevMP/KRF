--!strict
local RunService = game:GetService("RunService")

local ActionTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ActionControllerHooks = require(script.Parent.ActionControllerHooks)

type Actor = ActorTypes.Actor
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type OnUpdate = ActionTypes.OnUpdate
type UpdateRecord = {
	actor: Actor,
	actionId: string,
	context: ActionExecutionContext,
	callback: OnUpdate,
	interrupt: (number, string) -> (boolean, string?),
	lastUpdateAt: number,
}
type ControllerKey = {}
type ControllerSnapshot = { key: ControllerKey, sequenceIds: { number } }

local minimumIntervalSeconds: number = 0.05
local updateFailureReason: string = "ActionUpdateFailed"
local recordsByController: { [ControllerKey]: { [number]: UpdateRecord } } = {}
local automaticSteppingEnabled: boolean = true
local heartbeatConnection: RBXScriptConnection? = nil
local accumulatedSeconds: number = 0
local clockForTests: (() -> number)? = nil

local ActionControllerUpdates = {}

local function hasUpdateEligibleInstances(): boolean
	return next(recordsByController) ~= nil
end

local function clock(): number
	if clockForTests ~= nil then
		return clockForTests()
	end
	return os.clock()
end

local function step(): ()
	local snapshots: { ControllerSnapshot } = {}
	for key: ControllerKey, records: { [number]: UpdateRecord } in recordsByController do
		local sequenceIds: { number } = {}
		for sequenceId: number in records do
			table.insert(sequenceIds, sequenceId)
		end
		table.sort(sequenceIds)
		table.insert(snapshots, { key = key, sequenceIds = sequenceIds })
	end

	for _, snapshot: ControllerSnapshot in snapshots do
		for _, sequenceId: number in snapshot.sequenceIds do
			local records: { [number]: UpdateRecord }? = recordsByController[snapshot.key]
			local record: UpdateRecord? = if records ~= nil then records[sequenceId] else nil
			if record ~= nil then
				local currentTime: number = clock()
				local deltaTime: number = currentTime - record.lastUpdateAt
				if math.isfinite(deltaTime) and deltaTime > 0 then
					record.lastUpdateAt = currentTime
					local succeeded: boolean, _first: any, _second: any, failureKind: string?, failureDetail: any =
						ActionControllerHooks.RunNonSuspending(record.callback, record.context, deltaTime)
					if not succeeded then
						warn(
							"[ActionController] onUpdate failed actorId="
								.. record.actor:GetId()
								.. " actionId="
								.. record.actionId
								.. " sequenceId="
								.. tostring(sequenceId)
								.. " reason="
								.. tostring(failureDetail or failureKind)
						)
						local currentRecords: { [number]: UpdateRecord }? = recordsByController[snapshot.key]
						if currentRecords ~= nil and currentRecords[sequenceId] == record then
							record.interrupt(sequenceId, updateFailureReason)
						end
					end
				end
			end
		end
	end
end

local function heartbeat(deltaTime: number): ()
	if not hasUpdateEligibleInstances() or not math.isfinite(deltaTime) or deltaTime <= 0 then
		return
	end
	accumulatedSeconds += deltaTime
	if accumulatedSeconds < minimumIntervalSeconds then
		return
	end
	accumulatedSeconds = 0
	step()
end

local function reconcileConnection(): ()
	local hasEligibleInstances: boolean = hasUpdateEligibleInstances()
	if automaticSteppingEnabled and hasEligibleInstances then
		if heartbeatConnection == nil then
			accumulatedSeconds = 0
			heartbeatConnection = RunService.Heartbeat:Connect(heartbeat)
		end
		return
	end
	if heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
		accumulatedSeconds = 0
	elseif not hasEligibleInstances then
		accumulatedSeconds = 0
	end
end

function ActionControllerUpdates.Register(
	key: ControllerKey,
	actor: Actor,
	actionId: string,
	sequenceId: number,
	context: ActionExecutionContext,
	callback: OnUpdate,
	interrupt: (number, string) -> (boolean, string?)
): ()
	local existingRecords: { [number]: UpdateRecord }? = recordsByController[key]
	local records: { [number]: UpdateRecord } = if existingRecords == nil then {} else existingRecords
	recordsByController[key] = records
	assert(records[sequenceId] == nil, "ActionUpdateAlreadyRegistered")
	records[sequenceId] = {
		actor = actor,
		actionId = actionId,
		context = context,
		callback = callback,
		interrupt = interrupt,
		lastUpdateAt = clock(),
	}
	reconcileConnection()
end

function ActionControllerUpdates.Remove(key: ControllerKey, sequenceId: number): ()
	local records: { [number]: UpdateRecord } = assert(recordsByController[key], "ActionUpdateNotRegistered")
	assert(records[sequenceId] ~= nil, "ActionUpdateNotRegistered")
	records[sequenceId] = nil
	if next(records) == nil then
		recordsByController[key] = nil
	end
	reconcileConnection()
end

function ActionControllerUpdates._setClockForTests(value: (() -> number)?): ()
	clockForTests = value
end

function ActionControllerUpdates._setAutomaticSteppingEnabledForTests(enabled: boolean): ()
	automaticSteppingEnabled = enabled
	reconcileConnection()
end

function ActionControllerUpdates._heartbeatForTests(deltaTime: number): ()
	heartbeat(deltaTime)
end

function ActionControllerUpdates._isSchedulerConnectedForTests(): boolean
	return heartbeatConnection ~= nil
end

function ActionControllerUpdates._hasUpdateEligibleInstancesForTests(): boolean
	return hasUpdateEligibleInstances()
end

return ActionControllerUpdates
