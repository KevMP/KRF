--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

-- Callers can inspect the original contract and compare reservation identity;
-- correlation closure and follow-up retirement remain private to this owner.
export type Start = {
	read admission: Types.ActionRequestAdmission,
	read request: ActionRequestTypes.CompiledActionRequest,
}

type Original = Start & { correlationClosed: boolean, retired: boolean }

export type Owner = {
	CanStart: () -> boolean,
	CanFollowUp: () -> boolean,
	ReserveStart: (
		number,
		ActorTypes.ActorView,
		Types.ActionStartSelection,
		ActionRequestTypes.CompiledActionRequest
	) -> Types.ActionRequestAdmission,
	ReserveFollowUp: (number, Types.ActionRequestKind, Types.ActionRequestAdmission) -> Types.ActionRequestAdmission,
	GetStart: (number) -> Start?,
	ContainsStart: (number, Start) -> boolean,
	RemoveStart: (number) -> (),
	RemoveFollowUp: (number) -> (),
	Retire: (number) -> (),
	Expire: (number, string) -> (),
	Receive: (NetworkingTypes.CommandResult) -> Types.ActionRequestOutcome?,
	Count: () -> number,
	Destroy: () -> (),
}

local COMMAND_KINDS: { [string]: Types.ActionRequestKind } = {
	[Constants.START_COMMAND_ID] = "Start",
	[Constants.STOP_COMMAND_ID] = "Stop",
	[Constants.INTERRUPT_COMMAND_ID] = "Interrupt",
}

table.freeze(COMMAND_KINDS)

local Correlation = {}

local function hasFollowUps(request: ActionRequestTypes.CompiledActionRequest): boolean
	return request.stop ~= nil or request.allowInputInterrupt
end

-- Follow-up authority and late-result correlation have independent lifetimes.
-- This is the sole owner of both retained maps and their capacity accounting.
function Correlation.new(incarnation: number, maximum: number, removePending: (number) -> ()): Owner
	local originals: { [number]: Original } = {}
	local originalCount: number = 0
	-- Interrupt correlation survives Unknown until a definitive result or N9 expiry.
	local followUps: { [number]: Types.ActionRequestAdmission } = {}
	local followUpCount: number = 0

	local function removeStart(requestId: number): ()
		if originals[requestId] ~= nil then
			originals[requestId] = nil
			originalCount -= 1
			removePending(requestId)
		end
	end

	local function removeFollowUp(requestId: number): ()
		if followUps[requestId] ~= nil then
			followUps[requestId] = nil
			followUpCount -= 1
		end
	end

	local function retire(requestId: number): ()
		Observers.CheckReentry()
		local original: Original? = originals[requestId]

		if original ~= nil then
			original.retired = true
			removePending(requestId)

			if original.correlationClosed then
				removeStart(requestId)
			end
		end
	end

	local function receive(result: NetworkingTypes.CommandResult): Types.ActionRequestOutcome?
		local kind: Types.ActionRequestKind? = COMMAND_KINDS[result.commandId]

		if kind == nil then
			return nil
		end

		local admission: Types.ActionRequestAdmission
		local sequenceId: number? = nil

		if kind == "Start" then
			local original: Original? = originals[result.requestId]

			if original == nil or original.correlationClosed then
				return nil
			end

			admission = original.admission

			if result.status == "Accepted" then
				original.correlationClosed = true
				sequenceId = if type(result.result) == "table" then result.result.sequenceId else nil

				if original.retired or not hasFollowUps(original.request) then
					removeStart(result.requestId)
				end
			elseif result.status == "Rejected" then
				removeStart(result.requestId)
			end
		else
			local followUp: Types.ActionRequestAdmission? = followUps[result.requestId]

			if followUp == nil or followUp.kind ~= kind then
				return nil
			end

			admission = followUp

			-- Never replay Unknown. Retain Interrupt metadata during grace so a late
			-- Accepted result can release authority for its definitively ended original.
			if kind ~= "Interrupt" or result.status ~= "Unknown" then
				removeFollowUp(result.requestId)
			end

			if kind == "Interrupt" and result.status == "Accepted" then
				retire(admission.originalStartRequestId)
			end
		end

		return table.freeze({
			admission = admission,
			status = result.status,
			sequenceId = sequenceId,
			reason = result.reason,
		})
	end

	return {
		CanStart = function(): boolean
			return originalCount < maximum
		end,
		CanFollowUp = function(): boolean
			return followUpCount < maximum * 2
		end,
		ReserveStart = function(requestId, actor, selection, request): Types.ActionRequestAdmission
			local key: string = string.format("%.0f:%.0f", incarnation, requestId)

			local admission: Types.ActionRequestAdmission = table.freeze({
				kind = "Start" :: Types.ActionRequestKind,
				incarnation = incarnation,
				requestId = requestId,
				originalStartRequestId = requestId,
				actor = actor,
				actionId = request.actionId,
				origin = selection.origin,
				inputTimestamp = selection.inputTimestamp,
				requestKey = key,
				originalStartKey = key,
			})

			originals[requestId] =
				{ admission = admission, request = request, correlationClosed = false, retired = false }

			originalCount += 1

			return admission
		end,
		ReserveFollowUp = function(requestId, kind, start): Types.ActionRequestAdmission
			local admission: Types.ActionRequestAdmission = table.freeze({
				kind = kind,
				incarnation = incarnation,
				requestId = requestId,
				originalStartRequestId = start.requestId,
				actor = start.actor,
				actionId = start.actionId,
				origin = start.origin,
				inputTimestamp = nil,
				requestKey = string.format("%.0f:%.0f", incarnation, requestId),
				originalStartKey = start.requestKey,
			})

			followUps[requestId] = admission
			followUpCount += 1

			return admission
		end,
		GetStart = function(requestId): Start?
			local original: Original? = originals[requestId]

			return if original ~= nil and not original.retired then original else nil
		end,
		ContainsStart = function(requestId, original): boolean
			return originals[requestId] == original
		end,
		RemoveStart = removeStart,
		RemoveFollowUp = removeFollowUp,
		Retire = retire,
		Receive = receive,
		-- Losing late-result correlation does not prove denial or end a possible live
		-- activation. Its receipt remains usable only when the wire permits follow-ups.
		Expire = function(requestId, commandId): ()
			if commandId == Constants.INTERRUPT_COMMAND_ID then
				local followUp: Types.ActionRequestAdmission? = followUps[requestId]

				if followUp ~= nil and followUp.kind == "Interrupt" then
					removeFollowUp(requestId)
				end

				return
			end

			local original: Original? = originals[requestId]

			if commandId ~= Constants.START_COMMAND_ID or original == nil then
				return
			end

			original.correlationClosed = true

			if original.retired or not hasFollowUps(original.request) then
				removeStart(requestId)
			end
		end,
		Count = function(): number
			return originalCount + followUpCount
		end,
		Destroy = function(): ()
			table.clear(originals)
			table.clear(followUps)
			originalCount = 0
			followUpCount = 0
		end,
	}
end

return Correlation
