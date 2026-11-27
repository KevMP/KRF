--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ActionTypes = require(script.Parent.Parent.Parent.Action.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)

local MAX_TRANSITIONS: number = 8

export type Attempt = {
	actor: ActorTypes.ActorView,
	actionId: string,
	originalStartKey: string,
	startStatus: Types.LocalPredictionStatus,
	startReason: string?,
	sequenceId: number?,
	transitions: { Types.LocalPredictionInputDecision },
	lastStop: Types.LocalPredictionFollowUp?,
	lastInterrupt: Types.LocalPredictionFollowUp?,
	sidecar: RequestTypes.ActionStartPayload?,
	evaluated: boolean,
	claims: { [Types.PresentationDefinition]: boolean },
	authoritative: { [Types.PresentationDefinition]: boolean },
	matched: boolean,
	startObserved: boolean,
	live: number,
	retired: boolean,
	stale: boolean,
	expiry: (() -> ())?,
	revision: number,
	snapshot: Types.LocalPredictionSnapshot?,
	association: Types.PresentationActionAssociation,
	observers: { [() -> ()]: boolean },
	link: Types.PresentationPredictionLink,
}

export type HintPredictor = (Attempt, string, ActorTypes.ActorView?, any?) -> (boolean, string?)

local Attempt = {}

local function associate(attempt: Attempt): ()
	attempt.association = table.freeze({
		actor = attempt.actor,
		actionId = attempt.actionId,
		sequenceId = attempt.sequenceId,
		awaitingStart = attempt.sequenceId ~= nil and not attempt.startObserved,
	})
end

local function wake(attempt: Attempt): ()
	for observer: () -> () in table.clone(attempt.observers) do
		observer()
	end
end

local function notify(attempt: Attempt): ()
	attempt.revision += 1
	attempt.snapshot = nil
	wake(attempt)
end

local function settled(status: Types.LocalPredictionStatus): boolean
	return status == "Accepted" or status == "Rejected"
end

function Attempt.new(fact: ActionTypes.ActionRequestAdmitted, predictHint: HintPredictor): Attempt
	local current: Attempt? = nil

	local function owner(): Attempt
		return assert(current, "Prediction link requires its attempt")
	end

	local link: Types.PresentationPredictionLink = table.freeze({
		GetAssociation = function(): Types.PresentationActionAssociation
			return owner().association
		end,
		GetSnapshot = function(): (Types.LocalPredictionSnapshot, number)
			local attempt: Attempt = owner()

			return Attempt.Snapshot(attempt), attempt.revision
		end,
		Observe = function(observer: () -> ()): () -> ()
			local attempt: Attempt = owner()
			attempt.observers[observer] = true

			return function(): ()
				attempt.observers[observer] = nil
			end
		end,
		PredictHint = function(hintId: string, target: ActorTypes.ActorView?, payload: any?): (boolean, string?)
			return predictHint(owner(), hintId, target, payload)
		end,
	})

	local attempt: Attempt = {
		actor = fact.actor,
		actionId = fact.actionId,
		originalStartKey = fact.originalStartKey,
		startStatus = "Admitted",
		startReason = nil,
		sequenceId = nil,
		transitions = {},
		lastStop = nil,
		lastInterrupt = nil,
		sidecar = nil,
		evaluated = false,
		claims = {},
		authoritative = {},
		matched = false,
		startObserved = false,
		live = 0,
		retired = false,
		stale = false,
		expiry = nil,
		revision = 0,
		snapshot = nil,
		association = table.freeze({ actor = fact.actor, actionId = fact.actionId, sequenceId = nil }),
		observers = {},
		link = link,
	}

	current = attempt

	return attempt
end

function Attempt.Snapshot(attempt: Attempt): Types.LocalPredictionSnapshot
	local cached: Types.LocalPredictionSnapshot? = attempt.snapshot

	if cached ~= nil then
		return cached
	end

	local snapshot: Types.LocalPredictionSnapshot = table.freeze({
		startStatus = attempt.startStatus,
		startReason = attempt.startReason,
		sequenceId = attempt.sequenceId,
		inputTransitions = table.freeze(table.clone(attempt.transitions)),
		lastStop = attempt.lastStop,
		lastInterrupt = attempt.lastInterrupt,
	})

	attempt.snapshot = snapshot

	return snapshot
end

function Attempt.Apply(attempt: Attempt, fact: ActionTypes.ActionRequestEvent): (boolean, string?)
	if fact.kind == "RequestAdmitted" then
		assert(fact.operation ~= "Start", "An original Start admission creates its attempt")

		local admitted: Types.LocalPredictionFollowUp =
			table.freeze({ requestKey = fact.requestKey, status = "Admitted" :: "Admitted", reason = nil })

		if fact.operation == "Stop" then
			attempt.lastStop = admitted
		else
			attempt.lastInterrupt = admitted
		end
	elseif fact.kind == "RequestOutcome" then
		if fact.operation == "Start" then
			if settled(attempt.startStatus) or fact.status == attempt.startStatus then
				return false, nil
			end

			attempt.startStatus = fact.status
			attempt.startReason = fact.reason

			if fact.status == "Accepted" then
				attempt.sequenceId = fact.sequenceId
				associate(attempt)
			end
		else
			local current: Types.LocalPredictionFollowUp? = if fact.operation == "Stop"
				then attempt.lastStop
				else attempt.lastInterrupt

			if
				current == nil
				or current.requestKey ~= fact.requestKey
				or settled(current.status)
				or current.status == fact.status
			then
				return false, nil
			end

			local updated: Types.LocalPredictionFollowUp =
				table.freeze({ requestKey = fact.requestKey, status = fact.status, reason = fact.reason })

			if fact.operation == "Stop" then
				attempt.lastStop = updated
			else
				attempt.lastInterrupt = updated
			end
		end
	else
		if #attempt.transitions >= MAX_TRANSITIONS then
			return false, "PredictionTransitionLimit"
		end

		table.insert(
			attempt.transitions,
			table.freeze({ transition = fact.transition, reason = fact.reason, eventOrdinal = fact.eventOrdinal })
		)
	end

	notify(attempt)

	return true, nil
end

function Attempt.ObserveStart(attempt: Attempt): ()
	if attempt.startObserved then
		return
	end

	attempt.startObserved = true
	associate(attempt)
	wake(attempt)
end

function Attempt.IsCandidate(attempt: Attempt, actionId: string): boolean
	return not attempt.retired
		and not attempt.stale
		and attempt.actionId == actionId
		and attempt.sequenceId == nil
		and attempt.startStatus ~= "Rejected"
		and (not attempt.evaluated or next(attempt.claims) ~= nil)
end

return table.freeze(Attempt)
