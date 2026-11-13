--!strict
local Types = require(script.Parent.Parent.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)

local Facts = {}

-- Explicit projections keep parameters, callbacks and native recognition objects
-- in their owners. Every public variant is checked as its actual tagged type.
function Facts.Admitted(
	value: RequestTypes.ActionRequestAdmission,
	metadata: Types.ObservationMetadata
): Types.ActionRequestAdmitted
	local fact: Types.ActionRequestAdmitted = {
		kind = "RequestAdmitted",
		operation = value.kind,
		requestId = value.requestId,
		requestKey = value.requestKey,
		inputOccurredAt = if value.kind == "Start" and value.origin == "Input" then value.inputTimestamp else nil,
		actor = value.actor,
		actionId = value.actionId,
		origin = value.origin,
		originalStartRequestId = value.originalStartRequestId,
		originalStartKey = value.originalStartKey,
		eventOrdinal = metadata.eventOrdinal,
		observedAt = metadata.observedAt,
	}

	return table.freeze(fact)
end

function Facts.Outcome(
	value: RequestTypes.ActionRequestOutcome,
	metadata: Types.ObservationMetadata
): Types.ActionRequestOutcome
	local admission: RequestTypes.ActionRequestAdmission = value.admission
	local operation: Types.ActionRequestOperation = admission.kind
	local fact: Types.ActionRequestOutcome

	if value.status == "Accepted" then
		if operation == "Start" then
			fact = {
				kind = "RequestOutcome",
				operation = "Start" :: "Start",
				status = "Accepted" :: "Accepted",
				sequenceId = assert(value.sequenceId, "ActionObservationSequenceMissing"),
				reason = value.reason,
				requestId = admission.requestId,
				requestKey = admission.requestKey,
				actor = admission.actor,
				actionId = admission.actionId,
				origin = admission.origin,
				originalStartRequestId = admission.originalStartRequestId,
				originalStartKey = admission.originalStartKey,
				eventOrdinal = metadata.eventOrdinal,
				observedAt = metadata.observedAt,
			}
		else
			fact = {
				kind = "RequestOutcome",
				operation = operation,
				status = "Accepted" :: "Accepted",
				sequenceId = nil,
				reason = value.reason,
				requestId = admission.requestId,
				requestKey = admission.requestKey,
				actor = admission.actor,
				actionId = admission.actionId,
				origin = admission.origin,
				originalStartRequestId = admission.originalStartRequestId,
				originalStartKey = admission.originalStartKey,
				eventOrdinal = metadata.eventOrdinal,
				observedAt = metadata.observedAt,
			}
		end
	else
		fact = {
			kind = "RequestOutcome",
			operation = operation,
			status = value.status,
			sequenceId = nil,
			reason = value.reason,
			requestId = admission.requestId,
			requestKey = admission.requestKey,
			actor = admission.actor,
			actionId = admission.actionId,
			origin = admission.origin,
			originalStartRequestId = admission.originalStartRequestId,
			originalStartKey = admission.originalStartKey,
			eventOrdinal = metadata.eventOrdinal,
			observedAt = metadata.observedAt,
		}
	end

	return table.freeze(fact)
end

function Facts.Transition(
	value: Types.ActionInputDecision,
	metadata: Types.ObservationMetadata
): Types.ActionInputTransition
	local original: RequestTypes.ActionRequestAdmission = value.original

	local fact: Types.ActionInputTransition = {
		kind = "InputTransition",
		transition = value.kind,
		reason = value.reason,
		actor = original.actor,
		actionId = original.actionId,
		origin = original.origin,
		originalStartRequestId = original.originalStartRequestId,
		originalStartKey = original.originalStartKey,
		eventOrdinal = metadata.eventOrdinal,
		observedAt = metadata.observedAt,
	}

	return table.freeze(fact)
end

return Facts
