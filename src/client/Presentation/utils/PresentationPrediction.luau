--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ActionTypes = require(script.Parent.Parent.Parent.Action.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local PayloadCodec = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)
local CommandConstants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Attempts = require(script.Parent.PresentationPredictionAttempt)
local Deferrals = require(script.Parent.PresentationPredictionDeferrals)
local Eligibility = require(script.Parent.PresentationPredictionEligibility)
local Hints = require(script.Parent.PresentationPredictionHints)

type Attempt = Attempts.Attempt
type Definition = Types.PresentationDefinition

export type PredictionHost = {
	read IsEligible: (ActorTypes.ActorView) -> boolean,
	read IsStateReady: (ActorTypes.ActorView) -> boolean,
	read Start: (
		ActorTypes.ActorView?,
		Definition,
		Types.PresentationEntry,
		Types.PresentationPredictionLink,
		() -> boolean,
		() -> ()
	) -> Types.PresentationContext?,
	read Report: (string, string, string) -> (),
	read ReportHint: (string, string) -> (),
}

export type PredictionOptions = {
	read Delay: (number, () -> ()) -> () -> (),
	read Measure: () -> number,
}

export type Prediction = {
	read Observe: (ActionTypes.ActionRequestEvent) -> (),
	read AttachPayload: (RequestTypes.ActionStartPayload) -> (),
	read Route: (Types.ActionEntryEvent, { Definition }, (Definition) -> ()) -> (),
	read RouteHint: (Types.HintEntryEvent, { Definition }, (Definition) -> ()) -> (),
	read RetireActor: (ActorTypes.ActorView) -> (),
	read ObserveBaseline: (ActorTypes.ActorView) -> (),
	read Destroy: () -> (),
}

local MAX_ATTEMPTS: number = 32
local MAX_DEFERRED: number = 32
local MAX_OBSERVED_STARTS: number = 32
local AMBIGUITY_WINDOW_SECONDS: number = 0.5
local HORIZON_SECONDS: number = CommandConstants.TIMEOUT_SECONDS + CommandConstants.GRACE_SECONDS

local Prediction = {}

function Prediction.new(
	catalog: Types.PresentationPredictionCatalog,
	host: PredictionHost,
	options: PredictionOptions
): Prediction
	local byKey: { [string]: Attempt } = {}
	local byActor: { [ActorTypes.ActorView]: { Attempt } } = {}
	local order: { Attempt } = {}
	local queued: { [Attempt]: boolean } = {}
	local starts: { [ActorTypes.ActorView]: { number } } = {}
	local deferrals: Deferrals.Deferrals
	local hints: Hints.HintPredictions

	local function report(actionId: string, actor: ActorTypes.ActorView, reason: string): ()
		host.Report(actionId, actor:GetId(), reason)
	end

	local function retire(attempt: Attempt): ()
		local attempts: { Attempt } = assert(byActor[attempt.actor], "Live attempt must be indexed by its Actor")

		attempt.retired = true
		attempt.sidecar = nil
		hints.Drop(attempt)
		byKey[attempt.originalStartKey] = nil
		table.remove(order, assert(table.find(order, attempt), "Live attempt must be ordered"))
		table.remove(attempts, assert(table.find(attempts, attempt), "Live attempt must be indexed"))

		if #attempts == 0 then
			byActor[attempt.actor] = nil
		end

		local expiry: (() -> ())? = attempt.expiry

		attempt.expiry = nil

		if expiry ~= nil then
			expiry()
		end
	end

	local function settle(attempt: Attempt): ()
		if attempt.retired or attempt.live > 0 or not attempt.evaluated then
			return
		elseif
			attempt.stale
			or attempt.startStatus == "Rejected"
			or (not hints.IsPending(attempt) and (attempt.matched or next(attempt.claims) == nil))
		then
			retire(attempt)
			deferrals.Resolve(attempt.actor)
		end
	end

	local function confirm(attempt: Attempt): ()
		local sequenceId: number? = attempt.sequenceId
		local observed: { number }? = starts[attempt.actor]

		if sequenceId ~= nil and observed ~= nil and table.find(observed, sequenceId) ~= nil then
			Attempts.ObserveStart(attempt)
		end
	end

	local function noteStart(actor: ActorTypes.ActorView, sequenceId: number): ()
		local observed: { number } = starts[actor] or {}

		starts[actor] = observed

		if table.find(observed, sequenceId) == nil then
			table.insert(observed, sequenceId)

			if #observed > MAX_OBSERVED_STARTS then
				table.remove(observed, 1)
			end
		end

		for _, attempt: Attempt in byActor[actor] or {} do
			confirm(attempt)
		end
	end

	local function find(actor: ActorTypes.ActorView, actionId: string, sequenceId: number): Attempt?
		for _, attempt: Attempt in byActor[actor] or {} do
			if attempt.actionId == actionId and attempt.sequenceId == sequenceId then
				return attempt
			end
		end

		return nil
	end

	local function adopt(attempt: Attempt, definitions: { Definition }, deliver: (Definition) -> ()): ()
		attempt.matched = true

		for _, definition: Definition in definitions do
			if not attempt.claims[definition] then
				attempt.authoritative[definition] = true
				deliver(definition)
			end
		end

		settle(attempt)
	end

	local function classify(
		actor: ActorTypes.ActorView,
		action: ActorTypes.ActionSnapshot
	): (Deferrals.DeferralMatch, Deferrals.DeferralAdoption?)
		local exact: Attempt? = find(actor, action.actionId, action.sequenceId)

		if exact ~= nil then
			local matched: Attempt = exact

			return "Adopt",
				function(definitions: { Definition }, deliver: (Definition) -> ()): ()
					adopt(matched, definitions, deliver)
				end
		end

		for _, attempt: Attempt in byActor[actor] or {} do
			if Attempts.IsCandidate(attempt, action.actionId) then
				return "Hold", nil
			end
		end

		return "Release", nil
	end

	deferrals = Deferrals.new({
		Delay = options.Delay,
		WindowSeconds = AMBIGUITY_WINDOW_SECONDS,
		Capacity = MAX_DEFERRED,
	})

	local function launch(
		attempt: Attempt,
		actor: ActorTypes.ActorView?,
		definition: Definition,
		entry: Types.PresentationEntry
	): Types.PresentationContext?
		attempt.live += 1

		local context: Types.PresentationContext? = host.Start(
			actor,
			definition,
			entry,
			attempt.link,
			function(): boolean
				return attempt.startStatus ~= "Rejected"
			end,
			function(): ()
				attempt.live -= 1
				settle(attempt)
			end
		)

		if context == nil then
			attempt.live -= 1
		end

		return context
	end

	hints = Hints.new(catalog, {
		IsEligible = host.IsEligible,
		Start = function(
			attempt: Attempt,
			target: ActorTypes.ActorView?,
			definition: Definition,
			entry: Types.PredictedHintEntry
		): Types.PresentationContext?
			return launch(attempt, target, definition, entry)
		end,
		FindAttempts = function(actorId: string): { Attempt }
			for actor: ActorTypes.ActorView, attempts: { Attempt } in byActor do
				if actor:GetId() == actorId then
					return attempts
				end
			end

			return {}
		end,
		Changed = function(attempt: Attempt): ()
			settle(attempt)
			deferrals.Resolve(attempt.actor)
		end,
		Report = host.ReportHint,
		Delay = options.Delay,
	})

	local function reconcile(attempt: Attempt): ()
		if queued[attempt] then
			return
		end

		queued[attempt] = true

		task.defer(function(): ()
			queued[attempt] = nil
			settle(attempt)
			deferrals.Resolve(attempt.actor)
		end)
	end

	local function create(attempt: Attempt, definitions: { Definition }, sidecar: RequestTypes.ActionStartPayload): ()
		for _, definition: Definition in definitions do
			local decoded: boolean, parameters: any = PayloadCodec.Decode(sidecar.payload, sidecar.encoded)

			assert(decoded, "Previously decoded Start bytes must decode again")

			local entry: Types.PredictedActionEntry = table.freeze({
				source = "ActionPrediction" :: "ActionPrediction",
				event = "RequestAdmitted" :: "RequestAdmitted",
				actor = attempt.actor,
				actionId = attempt.actionId,
				originalStartKey = attempt.originalStartKey,
				parameters = parameters,
			})

			if launch(attempt, attempt.actor, definition, entry) ~= nil then
				attempt.claims[definition] = true
			end
		end
	end

	local function evaluate(attempt: Attempt): ()
		if attempt.retired then
			return
		end

		attempt.evaluated = true

		local sidecar: RequestTypes.ActionStartPayload? = attempt.sidecar

		attempt.sidecar = nil

		local pending: { Definition } = {}

		for _, definition: Definition in catalog.definitions[attempt.actionId] do
			if not attempt.authoritative[definition] then
				table.insert(pending, definition)
			end
		end

		if attempt.startStatus ~= "Rejected" and #pending > 0 and host.IsEligible(attempt.actor) then
			local decoded: boolean, parameters: any = false, nil

			if sidecar ~= nil then
				decoded, parameters = PayloadCodec.Decode(sidecar.payload, sidecar.encoded)
			end

			if not decoded then
				report(
					attempt.actionId,
					attempt.actor,
					if sidecar == nil then "PredictionParametersUnavailable" else "PredictionParametersInvalid"
				)
			else
				local context: Types.ActionPredictionCheckContext = table.freeze({
					actor = attempt.actor,
					actionId = attempt.actionId,
					originalStartKey = attempt.originalStartKey,
					parameters = parameters,
				})

				local estimate: Types.ActionPredictionEstimate, _reason: string?, diagnostic: string? =
					Eligibility.Estimate(
						catalog.policies[attempt.actionId],
						attempt.actor,
						host.IsStateReady(attempt.actor),
						context,
						options.Measure
					)

				if diagnostic ~= nil then
					report(attempt.actionId, attempt.actor, "Prediction" .. diagnostic)
				end

				if estimate == "LikelyAllowed" and not attempt.retired then
					create(attempt, pending, assert(sidecar, "Decoded parameters require a sidecar"))
				end
			end
		end

		settle(attempt)
		deferrals.Resolve(attempt.actor)
	end

	local function admit(fact: ActionTypes.ActionRequestAdmitted): ()
		if catalog.definitions[fact.actionId] == nil then
			return
		end

		if #order >= MAX_ATTEMPTS then
			local evicted: Attempt? = nil

			for _, candidate: Attempt in order do
				if candidate.live == 0 and candidate.evaluated then
					if not hints.IsPending(candidate) then
						evicted = candidate

						break
					elseif evicted == nil then
						evicted = candidate
					end
				end
			end

			if evicted ~= nil then
				retire(evicted)
				task.defer(deferrals.Resolve, evicted.actor)
			end
		end

		if #order >= MAX_ATTEMPTS then
			task.defer(report, fact.actionId, fact.actor, "PredictionAttemptLimit")

			return
		end

		local attempt: Attempt = Attempts.new(
			fact,
			function(owner: Attempt, hintId: string, target: ActorTypes.ActorView?, payload: any?): (boolean, string?)
				return hints.Predict(owner, hintId, target, payload)
			end
		)

		local attempts: { Attempt } = byActor[fact.actor] or {}

		byActor[fact.actor] = attempts
		byKey[fact.originalStartKey] = attempt
		table.insert(attempts, attempt)
		table.insert(order, attempt)

		attempt.expiry = options.Delay(HORIZON_SECONDS, function(): ()
			attempt.expiry = nil
			attempt.stale = true
			Attempts.ObserveStart(attempt)

			if attempt.live == 0 then
				retire(attempt)
			end

			deferrals.Resolve(attempt.actor)
		end)

		task.defer(evaluate, attempt)
	end

	return table.freeze({
		Observe = function(fact: ActionTypes.ActionRequestEvent): ()
			if fact.kind == "RequestAdmitted" and fact.operation == "Start" then
				admit(fact)

				return
			end

			local attempt: Attempt? = byKey[fact.originalStartKey]

			if attempt == nil then
				return
			end

			local changed: boolean, diagnostic: string? = Attempts.Apply(attempt, fact)

			if diagnostic ~= nil then
				task.defer(report, attempt.actionId, attempt.actor, diagnostic)
			end

			if changed and fact.kind == "RequestOutcome" and fact.operation == "Start" then
				confirm(attempt)
				hints.Assign(attempt)
				reconcile(attempt)
			end
		end,
		AttachPayload = function(sidecar: RequestTypes.ActionStartPayload): ()
			local admission: RequestTypes.ActionRequestAdmission = sidecar.admission
			local attempt: Attempt? = byKey[admission.originalStartKey]

			if
				attempt ~= nil
				and not attempt.evaluated
				and attempt.sidecar == nil
				and admission.kind == "Start"
				and admission.actor == attempt.actor
				and admission.actionId == attempt.actionId
			then
				attempt.sidecar = sidecar
			end
		end,
		Route = function(entry: Types.ActionEntryEvent, definitions: { Definition }, deliver: (Definition) -> ()): ()
			noteStart(entry.actor, entry.action.sequenceId)

			local match: Deferrals.DeferralMatch, adoption: Deferrals.DeferralAdoption? =
				classify(entry.actor, entry.action)

			if match == "Adopt" then
				assert(adoption, "Adopt requires an adoption")(definitions, deliver)

				return
			elseif match == "Hold" then
				local held: boolean = deferrals.Hold(
					entry.actor,
					function(): (Deferrals.DeferralMatch, Deferrals.DeferralAdoption?)
						return classify(entry.actor, entry.action)
					end,
					definitions,
					deliver
				)

				if held then
					return
				end

				report(entry.action.actionId, entry.actor, "PredictionDeferredLimit")
			end

			for _, definition: Definition in definitions do
				deliver(definition)
			end
		end,
		RouteHint = function(entry: Types.HintEntryEvent, definitions: { Definition }, deliver: (Definition) -> ()): ()
			local match: Deferrals.DeferralMatch, adoption: Deferrals.DeferralAdoption?, holder: ActorTypes.ActorView? =
				hints.Classify(entry)

			if match == "Adopt" then
				assert(adoption, "Adopt requires an adoption")(definitions, deliver)

				return
			elseif match == "Hold" then
				local held: boolean = deferrals.Hold(
					assert(holder, "Hold requires the candidate's Actor"),
					function(): (Deferrals.DeferralMatch, Deferrals.DeferralAdoption?)
						local current: Deferrals.DeferralMatch, currentAdoption: Deferrals.DeferralAdoption? =
							hints.Classify(entry)

						return current, currentAdoption
					end,
					definitions,
					deliver
				)

				if held then
					return
				end

				host.ReportHint(entry.hintId, "PredictionDeferredLimit")
			end

			for _, definition: Definition in definitions do
				deliver(definition)
			end
		end,
		RetireActor = function(actor: ActorTypes.ActorView): ()
			starts[actor] = nil
			hints.DropActor(actor:GetId())

			for _, attempt: Attempt in table.clone(byActor[actor] or {}) do
				retire(attempt)
			end

			deferrals.Resolve(actor)
			deferrals.Drop(actor)
		end,
		ObserveBaseline = function(actor: ActorTypes.ActorView): ()
			for _, attempt: Attempt in table.clone(byActor[actor] or {}) do
				if attempt.sequenceId ~= nil then
					Attempts.ObserveStart(attempt)
				end
			end
		end,
		Destroy = function(): ()
			deferrals.Destroy()
			hints.Destroy()
			table.clear(starts)

			for _, attempt: Attempt in table.clone(order) do
				retire(attempt)
			end
		end,
	})
end

return table.freeze(Prediction)
