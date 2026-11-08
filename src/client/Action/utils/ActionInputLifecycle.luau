--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local SharedRequestTypes = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Activations = require(script.Parent.ActionInputActivations)
local Selection = require(script.Parent.ActionInputSelection)
local Parameters = require(script.Parent.ActionInputParameters)
local FollowUps = require(script.Parent.Parent.Parent.ActionRequest.utils.ActionFollowUpQueue)
local Registry = require(script.Parent.Parent.Parent.Actor.utils.ActorViewRegistryState)

export type Options = {
	Input: InputTypes.InputOwner,
	Requests: RequestTypes.ClientActionRequestRuntime,
	Policies: Types.ActionInputCatalog,
	IsReady: () -> boolean,
	Report: (string) -> (),
}

local Lifecycle = {}

local function interruptReason(reason: string): SharedRequestTypes.ActionInputInterruptReason
	if string.find(reason, "Actor", 1, true) then
		return "ActorSwitched"
	elseif string.find(reason, "Focus", 1, true) then
		return "FocusLost"
	elseif string.find(reason, "Context", 1, true) then
		return "ContextDisabled"
	end

	return "RouteInvalidated"
end

function Lifecycle.new(options: Options): Types.ActionInputOwner
	local input: InputTypes.InputOwner = options.Input
	local requests: RequestTypes.ClientActionRequestRuntime = options.Requests
	local store: Activations.Owner = Activations.new()

	local decisions =
		Observers.new(16, "ActionInputObserverLimitExceeded") :: Observers.Registry<(Types.ActionInputDecision) -> ()>

	local routes: Types.ActionInputRoutePort? = nil
	local disconnects: { () -> () } = {}
	local reported: { [string]: boolean } = {}
	local destroyed: boolean = false
	local queued: boolean = false
	local retired: { Activations.Record } = {}
	local pump: (Activations.Record) -> ()

	local function destroy(): ()
		destroyed = true
		store.Destroy()
		table.clear(retired)
		decisions.Destroy()

		for _, disconnect in disconnects do
			disconnect()
		end

		table.clear(disconnects)
		routes = nil
	end

	local function report(reason: string): ()
		if not reported[reason] then
			reported[reason] = true
			options.Report(reason)
		end
	end

	local function decision(record: Activations.Record, kind: Types.ActionInputDecisionKind, reason: string): ()
		local original: RequestTypes.ActionRequestAdmission = assert(record.admission, "Expected original admission")

		local fact: Types.ActionInputDecision = table.freeze({
			kind = kind,
			original = original,
			generation = record.identity.generation,
			reason = string.sub(reason, 1, 96),
		})

		requests:StageDecision(original.requestId, function(): ()
			if not destroyed then
				for _, entry in decisions.Snapshot() do
					if entry.active then
						Observers.Run(entry.callback, fact)
					end
				end
			end
		end)
	end

	-- Admission ends automatic authority before physical egress can reenter Input.
	-- I5 keeps any unsettled Start result correlation independently.
	local function close(record: Activations.Record): ()
		record.delivery = "Complete"
		store.Remove(record)

		requests:Retire(assert(record.admission, "Expected admitted follow-up").requestId)
	end

	pump = function(record: Activations.Record): ()
		if
			destroyed
			or record.starting
			or record.busy
			or record.intent == nil
			or record.admission == nil
			or record.delivery == "Complete"
			or record.delivery == record.intent
		then
			return
		end

		local original: number = record.admission.requestId
		local pending: Types.ActionInputDecisionKind? = record.pendingDecision

		if pending ~= nil then
			record.pendingDecision = nil
			decision(record, pending, record.reason or pending)
		end

		if requests:GetOriginalStart(original) == nil then
			store.Remove(record)

			return
		end

		record.busy = true
		local requestId: number?, failure: string? = nil, nil

		local function committed(): ()
			close(record)
		end

		if record.intent == "Stop" then
			record.delivery = "Stop"

			local produced: boolean, value: any, reason: string? = Parameters.Produce(
				record.policy.stopParameters,
				Parameters.Context(record.identity, original, nil),
				nil
			)

			if destroyed or record.intent ~= "Stop" then
				record.busy = false
				pump(record)

				return
			end

			if record.live and produced then
				requestId, failure = requests:Stop(original, value, true, committed)
			else
				failure = reason
			end

			if record.live and (not produced or Parameters.IsEncodingFailure(failure)) then
				record.intent = "Interrupt"
				record.delivery = "Interrupt"
				record.reason = "StopPreparationFailed"

				report(reason or assert(failure, "Expected Stop preparation failure"))

				requestId, failure = requests:Interrupt(original, "StopPreparationFailed", true, committed)
			end
		elseif record.intent == "Interrupt" then
			record.delivery = "Interrupt"

			requestId, failure =
				requests:Interrupt(original, interruptReason(record.reason or "RouteInvalidated"), true, committed)
		end

		record.busy = false

		if requestId ~= nil or record.intent == "Keep" or not FollowUps.IsPressure(failure) then
			record.delivery = "Complete"
			store.Remove(record)
		else
			report(assert(failure, "Expected admission pressure"))
		end
	end

	local function flushRetired(): ()
		queued = false
		local batch: { Activations.Record } = retired
		retired = {}

		for _, record in batch do
			local kind: Types.ActionInputDecisionKind = if record.intent == "Interrupt"
				then "InvalidatedInterrupt"
				else "InvalidatedKeep"

			if record.admission ~= nil then
				decision(record, kind, record.reason or "RouteInvalidated")
			else
				record.pendingDecision = kind
			end

			pump(record)
		end
	end

	local function invalidate(records: { Activations.Record }, reason: string): ()
		for _, record in records do
			if record.live then
				store.Remove(record)
				record.intent = record.policy.onInvalidation
				record.reason = reason
				table.insert(retired, record)
			end
		end
	end

	local function afterCommit(): ()
		if not queued and #retired > 0 then
			queued = true

			Registry.AfterInvalidation(function(): ()
				local accepted: boolean = input.AfterCommit(flushRetired)

				if not accepted then
					table.clear(retired)
					queued = false
				end
			end)
		end
	end

	local function finish(record: Activations.Record, kind: "GenuineRelease" | "ToggleOff"): ()
		if record.intent ~= nil then
			return
		end

		store.ConsumeEpoch(record)
		store.Touch()
		record.intent = "Stop"

		if record.admission ~= nil then
			decision(record, kind, kind)
		else
			record.pendingDecision = kind
		end

		pump(record)
	end

	local function requestStatus(): string?
		if destroyed or not options.IsReady() then
			return "ClientNotReady"
		end

		local status: string? = input.GetMutationStatus()

		return if status == "InputMutationReentrant" or status == "InputMutationDuringValidation"
			then "DispatchInProgress"
			else nil
	end

	local function manual(
		original: number,
		send: (((RequestTypes.ActionRequestAdmission) -> ())?) -> (number?, string?)
	): (number?, string?)
		local unavailable: string? = requestStatus()

		if unavailable ~= nil then
			return nil, unavailable
		end

		local record: Activations.Record? = store.ByRequest(original)

		if record ~= nil then
			if record.busy then
				return nil, "ActionInputRequestInProgress"
			end

			record.busy = true
		end

		local requestId: number?, reason: string? = send(if record ~= nil
			then function(): ()
				close(record)
			end
			else nil)

		if record ~= nil then
			record.busy = false

			if requestId == nil then
				pump(record)
			end
		end

		return requestId, reason
	end

	local subscribed: boolean, failure: any = pcall(function(): ()
		table.insert(
			disconnects,
			requests:ObserveAdmissions(function(admission): ()
				local record: Activations.Record? = store.ByRequest(admission.originalStartRequestId)

				if record ~= nil and admission.kind == "Start" then
					record.starting = false
					pump(record)
				end
			end)
		)

		table.insert(
			disconnects,
			requests:ObserveOutcomes(function(outcome): ()
				if outcome.admission.kind == "Start" and outcome.status == "Rejected" then
					local record: Activations.Record? = store.ByRequest(outcome.admission.originalStartRequestId)

					if record ~= nil then
						store.Remove(record)
					end
				end
			end)
		)
	end)

	if not subscribed then
		destroy()
		error(failure, 0)
	end

	return {
		Select = Selection.new({
			Policies = options.Policies,
			CanDispatch = function(): boolean
				return not destroyed and options.IsReady()
			end,
			GetRoutes = function(): Types.ActionInputRoutePort?
				return routes
			end,
			IsPressEpochActive = function(inputId: string, epoch: number, generation: number): boolean
				return input.IsPressEpochActive(inputId, epoch, generation)
			end,
			Start = function(selection, parameters): (number?, string?)
				return requests:Start(selection, parameters)
			end,
			Store = { Add = store.Add, Bind = store.Bind, Remove = store.Remove, FindToggle = store.FindToggle },
			ToggleOff = function(record): ()
				finish(record, "ToggleOff")
			end,
			Flush = pump,
			Report = report,
		}),
		Attach = function(port): ()
			routes = port

			table.insert(
				disconnects,
				port.ObserveRoutes(function(change): ()
					local affected: { Activations.Record } = {}

					for _, record in store.ByRoute(change.actor, change.key) do
						if
							change.invalidated
							or change.next.status ~= "Mapped"
							or change.next.sourceId ~= record.identity.sourceId
							or change.next.version ~= record.identity.routeVersion
						then
							table.insert(affected, record)
						end
					end

					invalidate(affected, change.reason)
					afterCommit()
				end)
			)

			table.insert(
				disconnects,
				input.ObservePrimitive("Interpretation", function(occurrence): ()
					if occurrence.event.kind == "Released" then
						for _, record in store.ByEpoch(occurrence) do
							finish(record, "GenuineRelease")
						end
					elseif occurrence.event.kind == "Cancelled" then
						invalidate(store.ByEpoch(occurrence), occurrence.event.reason)
						afterCommit()
					end
				end)
			)
		end,
		Guard = {
			Revision = store.Revision,
			HasActive = store.HasActive,
			Prepare = function(previous): (Types.ActorSwitchRetirement?, string?)
				local snapshot = store.ByActor(previous)

				return {
					Commit = function(): ()
						invalidate(snapshot, "ActorSwitched")
					end,
					AfterCommit = afterCommit,
				},
					nil
			end,
		},
		RequestAction = function(actor, actionId, parameters): (number?, string?)
			local unavailable: string? = requestStatus()

			if unavailable ~= nil then
				return nil, unavailable
			end

			return requests:Start({ actor = actor, actionId = actionId, origin = "Direct" }, parameters)
		end,
		RequestStop = function(original, parameters): (number?, string?)
			return manual(original, function(committed): (number?, string?)
				return requests:Stop(original, parameters, nil, committed)
			end)
		end,
		RequestInterrupt = function(original, reason): (number?, string?)
			return manual(original, function(committed): (number?, string?)
				return requests:Interrupt(original, reason, nil, committed)
			end)
		end,
		ObserveDecisions = decisions.Add,
		Destroy = destroy,
	}
end

return Lifecycle
