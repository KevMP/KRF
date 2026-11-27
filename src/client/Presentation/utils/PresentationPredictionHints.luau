--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Attempts = require(script.Parent.PresentationPredictionAttempt)
local Deferrals = require(script.Parent.PresentationPredictionDeferrals)

type Attempt = Attempts.Attempt
type Definition = Types.PresentationDefinition

export type HintPredictionHost = {
	read IsEligible: (ActorTypes.ActorView) -> boolean,
	read Start: (Attempt, ActorTypes.ActorView?, Definition, Types.PredictedHintEntry) -> Types.PresentationContext?,
	read FindAttempts: (string) -> { Attempt },
	read Changed: (Attempt) -> (),
	read Report: (string, string) -> (),
	read Delay: (number, () -> ()) -> () -> (),
}

export type HintPredictions = {
	read Predict: (Attempt, string, ActorTypes.ActorView?, any?) -> (boolean, string?),
	read Classify: (
		Types.HintEntryEvent
	) -> (Deferrals.DeferralMatch, Deferrals.DeferralAdoption?, ActorTypes.ActorView?),
	read Assign: (Attempt) -> (),
	read IsPending: (Attempt) -> boolean,
	read Drop: (Attempt) -> (),
	read DropActor: (string) -> (),
	read Destroy: () -> (),
}

type HintRecord = {
	hintId: string,
	target: ActorTypes.ActorView?,
	claims: { [Definition]: boolean },
	cancel: (() -> ())?,
}

type HintLedger = { predicted: { HintRecord }, received: { HintRecord } }

type EarlyHint = {
	sequenceId: number,
	hintId: string,
	target: ActorTypes.ActorView?,
	cancel: (() -> ())?,
}

local MAX_PREDICTED: number = 16
local MAX_RECEIVED: number = 8
local MAX_EARLY: number = 8
local MATCH_WINDOW_SECONDS: number = 3

local Hints = {}

function Hints.new(catalog: Types.PresentationPredictionCatalog, host: HintPredictionHost): HintPredictions
	local ledgers: { [Attempt]: HintLedger } = {}
	local early: { [string]: { EarlyHint } } = {}

	local function ledgerFor(attempt: Attempt): HintLedger
		local ledger: HintLedger? = ledgers[attempt]

		if ledger ~= nil then
			return ledger
		end

		local created: HintLedger = { predicted = {}, received = {} }

		ledgers[attempt] = created

		return created
	end

	local function forget(attempt: Attempt, records: { HintRecord }, record: HintRecord): ()
		table.remove(records, assert(table.find(records, record), "Hint record must be indexed"))

		local cancel: (() -> ())? = record.cancel

		record.cancel = nil

		if cancel ~= nil then
			cancel()
		end

		local ledger: HintLedger? = ledgers[attempt]

		if ledger ~= nil and #ledger.predicted == 0 and #ledger.received == 0 then
			ledgers[attempt] = nil
		end
	end

	local function find(records: { HintRecord }, hintId: string, target: ActorTypes.ActorView?): HintRecord?
		for _, record: HintRecord in records do
			if record.hintId == hintId and record.target == target then
				return record
			end
		end

		return nil
	end

	local function remember(attempt: Attempt, records: { HintRecord }, record: HintRecord): ()
		table.insert(records, record)

		record.cancel = host.Delay(MATCH_WINDOW_SECONDS, function(): ()
			record.cancel = nil
			forget(attempt, records, record)
			host.Changed(attempt)
		end)
	end

	local function adopt(
		attempt: Attempt,
		entry: Types.HintEntryEvent,
		definitions: { Definition },
		deliver: (Definition) -> ()
	): ()
		local ledger: HintLedger? = ledgers[attempt]
		local predicted: HintRecord? = if ledger ~= nil then find(ledger.predicted, entry.hintId, entry.actor) else nil

		if predicted ~= nil and ledger ~= nil then
			forget(attempt, ledger.predicted, predicted)

			for _, definition: Definition in definitions do
				if not predicted.claims[definition] then
					deliver(definition)
				end
			end

			host.Changed(attempt)

			return
		end

		local remembered: HintLedger = ledgerFor(attempt)

		if #remembered.received < MAX_RECEIVED then
			remember(
				attempt,
				remembered.received,
				{ hintId = entry.hintId, target = entry.actor, claims = {}, cancel = nil }
			)
		end

		for _, definition: Definition in definitions do
			deliver(definition)
		end
	end

	local function cancelEarly(record: EarlyHint): ()
		local cancel: (() -> ())? = record.cancel

		record.cancel = nil

		if cancel ~= nil then
			cancel()
		end
	end

	local function removeEarly(actorId: string, record: EarlyHint): ()
		local records: { EarlyHint } = assert(early[actorId], "Early Hint must be indexed by its attacker")

		table.remove(records, assert(table.find(records, record), "Early Hint must be indexed"))

		if #records == 0 then
			early[actorId] = nil
		end

		cancelEarly(record)
	end

	local function rememberEarly(actorId: string, entry: Types.HintEntryEvent, sequenceId: number): ()
		local records: { EarlyHint } = early[actorId] or {}

		if #records >= MAX_EARLY then
			return
		end

		early[actorId] = records

		local record: EarlyHint = { sequenceId = sequenceId, hintId = entry.hintId, target = entry.actor, cancel = nil }

		table.insert(records, record)

		record.cancel = host.Delay(MATCH_WINDOW_SECONDS, function(): ()
			record.cancel = nil
			removeEarly(actorId, record)
		end)
	end

	local function unresolved(attempt: Attempt): boolean
		return not attempt.retired
			and not attempt.stale
			and attempt.sequenceId == nil
			and attempt.startStatus ~= "Rejected"
	end

	local function waiting(attempt: Attempt, hintId: string, target: ActorTypes.ActorView?): boolean
		local ledger: HintLedger? = ledgers[attempt]

		return unresolved(attempt) and ledger ~= nil and find(ledger.predicted, hintId, target) ~= nil
	end

	return table.freeze({
		Predict = function(
			attempt: Attempt,
			hintId: string,
			target: ActorTypes.ActorView?,
			payload: any?
		): (boolean, string?)
			local definitions: { Definition }? = catalog.hintDefinitions[hintId]

			if attempt.retired or attempt.stale then
				return false, "PredictionExpired"
			elseif attempt.startStatus == "Rejected" then
				return false, "PredictionRejected"
			elseif definitions == nil then
				return false, "HintNotPredicted"
			elseif target ~= nil and not host.IsEligible(target) then
				return false, "ActorUnavailable"
			end

			local existing: HintLedger? = ledgers[attempt]
			local received: HintRecord? = if existing ~= nil then find(existing.received, hintId, target) else nil

			if received ~= nil and existing ~= nil then
				forget(attempt, existing.received, received)

				return false, "HintAlreadyReceived"
			elseif existing ~= nil and #existing.predicted >= MAX_PREDICTED then
				return false, "PredictedHintLimit"
			end

			local owned: any = if type(payload) == "table" then table.freeze(table.clone(payload)) else payload

			local entry: Types.PredictedHintEntry = table.freeze({
				source = "HintPrediction" :: "HintPrediction",
				event = "Received" :: "Received",
				actor = target,
				hintId = hintId,
				payload = owned,
			})

			local claims: { [Definition]: boolean } = {}

			for _, definition: Definition in definitions do
				if host.Start(attempt, target, definition, entry) ~= nil then
					claims[definition] = true
				end
			end

			if next(claims) == nil then
				return false, "PredictionNotStarted"
			end

			local ledger: HintLedger = ledgerFor(attempt)

			remember(attempt, ledger.predicted, { hintId = hintId, target = target, claims = claims, cancel = nil })

			return true, nil
		end,
		Classify = function(
			entry: Types.HintEntryEvent
		): (Deferrals.DeferralMatch, Deferrals.DeferralAdoption?, ActorTypes.ActorView?)
			local policy: Types.HintPredictionPolicy =
				assert(catalog.hintPolicies[entry.hintId], "Predicted Hint definitions require a policy")

			local payload: any = entry.payload
			local actorId: any = if type(payload) == "table" then payload[policy.actorIdField] else nil
			local sequenceId: any = if type(payload) == "table" then payload[policy.sequenceIdField] else nil

			if type(actorId) ~= "string" or type(sequenceId) ~= "number" then
				host.Report(entry.hintId, "PredictionHintSourceInvalid")

				return "Release", nil, nil
			end

			local candidate: Attempt? = nil
			local pending: boolean = false

			for _, attempt: Attempt in host.FindAttempts(actorId) do
				if attempt.sequenceId == sequenceId then
					local matched: Attempt = attempt

					return "Adopt",
						function(definitions: { Definition }, deliver: (Definition) -> ()): ()
							adopt(matched, entry, definitions, deliver)
						end,
						nil
				elseif candidate == nil and waiting(attempt, entry.hintId, entry.actor) then
					candidate = attempt
				end

				pending = pending or unresolved(attempt)
			end

			if candidate ~= nil then
				return "Hold", nil, candidate.actor
			elseif pending then
				local source: string, activation: number = actorId, sequenceId

				return "Adopt",
					function(definitions: { Definition }, deliver: (Definition) -> ()): ()
						rememberEarly(source, entry, activation)

						for _, definition: Definition in definitions do
							deliver(definition)
						end
					end,
					nil
			end

			return "Release", nil, nil
		end,
		Assign = function(attempt: Attempt): ()
			local sequenceId: number? = attempt.sequenceId
			local actorId: string = attempt.actor:GetId()
			local records: { EarlyHint }? = early[actorId]

			if sequenceId == nil or records == nil then
				return
			end

			for _, record: EarlyHint in table.clone(records) do
				if record.sequenceId == sequenceId then
					removeEarly(actorId, record)

					local ledger: HintLedger = ledgerFor(attempt)
					local predicted: HintRecord? = find(ledger.predicted, record.hintId, record.target)

					if predicted ~= nil then
						forget(attempt, ledger.predicted, predicted)
					else
						remember(
							attempt,
							ledger.received,
							{ hintId = record.hintId, target = record.target, claims = {}, cancel = nil }
						)
					end
				end
			end
		end,
		IsPending = function(attempt: Attempt): boolean
			local ledger: HintLedger? = ledgers[attempt]

			return ledger ~= nil and #ledger.predicted > 0
		end,
		Drop = function(attempt: Attempt): ()
			local ledger: HintLedger? = ledgers[attempt]

			if ledger == nil then
				return
			end

			ledgers[attempt] = nil

			for _, records: { HintRecord } in { ledger.predicted, ledger.received } do
				for _, record: HintRecord in records do
					local cancel: () -> () = assert(record.cancel, "Indexed hint record owns its timer")

					record.cancel = nil
					cancel()
				end

				table.clear(records)
			end
		end,
		DropActor = function(actorId: string): ()
			for _, record: EarlyHint in table.clone(early[actorId] or {}) do
				removeEarly(actorId, record)
			end
		end,
		Destroy = function(): ()
			for actorId: string, records: { EarlyHint } in table.clone(early) do
				for _, record: EarlyHint in table.clone(records) do
					removeEarly(actorId, record)
				end
			end
		end,
	})
end

return table.freeze(Hints)
