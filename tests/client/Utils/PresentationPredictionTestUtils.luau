--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.client.Actor.types)
local ActionTypes = require(KRF.client.Action.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local SharedRequestTypes = require(KRF.shared.ActionRequest.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Types = require(KRF.client.Presentation.types)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Catalog = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local PayloadCodec = require(KRF.shared.ActionRequest.utils.ActionPayloadCodec)
local Validator = require(KRF.client.Presentation.ActionPredictionPolicyValidator)

export type Delay = { due: number, callback: () -> (), cancelled: boolean }

export type Port = {
	port: Types.PresentationPredictionPort,
	observers: { [(ActionTypes.ActionRequestEvent) -> ()]: boolean },
	payloads: { [(RequestTypes.ActionStartPayload) -> ()]: boolean },
	delays: { Delay },
	now: number,
	elapsed: number,
	ordinal: number,
	requestId: number,
}

export type Start = { key: string, requestId: number }

local TestUtils = {}

TestUtils.schemas = table.freeze({
	Fireball = { start = Schema.Struct({ aim = Schema.F32 }) },
	Dash = {},
	Charge = { start = Schema.Struct({ aim = Schema.F32 }), stop = {}, allowInputInterrupt = true },
}) :: SharedRequestTypes.ActionRequestSchemas

TestUtils.catalog = assert(Catalog.Compile(TestUtils.schemas))

function TestUtils.policies(value: Types.ActionPredictionPolicies): Types.ActionPredictionPolicyCatalog
	return assert(Validator.Compile(value, TestUtils.catalog))
end

function TestUtils.port(): Port
	local fixture: Port

	fixture = {
		port = {} :: Types.PresentationPredictionPort,
		observers = {},
		payloads = {},
		delays = {},
		now = 0,
		elapsed = 0,
		ordinal = 0,
		requestId = 0,
	}

	fixture.port = table.freeze({
		ObserveActionRequest = function(observer: (ActionTypes.ActionRequestEvent) -> ()): () -> ()
			fixture.observers[observer] = true

			return function(): ()
				fixture.observers[observer] = nil
			end
		end,
		ObserveStartPayloads = function(observer: (RequestTypes.ActionStartPayload) -> ()): () -> ()
			fixture.payloads[observer] = true

			return function(): ()
				fixture.payloads[observer] = nil
			end
		end,
		Delay = function(seconds: number, callback: () -> ()): () -> ()
			local scheduled: Delay = { due = fixture.now + seconds, callback = callback, cancelled = false }

			table.insert(fixture.delays, scheduled)

			return function(): ()
				scheduled.cancelled = true
			end
		end,
		Measure = function(): number
			return fixture.elapsed
		end,
	})

	return fixture
end

function TestUtils.advance(fixture: Port, seconds: number): ()
	fixture.now += seconds

	for _, scheduled: Delay in table.clone(fixture.delays) do
		if not scheduled.cancelled and scheduled.due <= fixture.now then
			scheduled.cancelled = true
			scheduled.callback()
		end
	end
end

function TestUtils.emit(fixture: Port, fact: ActionTypes.ActionRequestEvent): ()
	for observer in table.clone(fixture.observers) do
		observer(fact)
	end
end

local function metadata(fixture: Port): (number, number)
	fixture.ordinal += 1

	return fixture.ordinal, fixture.now
end

function TestUtils.admit(
	fixture: Port,
	actor: ActorTypes.ActorView,
	actionId: string,
	parameters: any?,
	options: { payload: boolean?, encoded: string?, origin: ("Input" | "Direct")? }?
): Start
	fixture.requestId += 1

	local requestId: number = fixture.requestId
	local key: string = "1:" .. requestId
	local origin: "Input" | "Direct" = if options ~= nil and options.origin ~= nil then options.origin else "Direct"
	local ordinal: number, observedAt: number = metadata(fixture)

	TestUtils.emit(
		fixture,
		table.freeze({
			kind = "RequestAdmitted" :: "RequestAdmitted",
			operation = "Start" :: "Start",
			requestId = requestId,
			requestKey = key,
			inputOccurredAt = nil,
			actor = actor,
			actionId = actionId,
			origin = origin,
			originalStartRequestId = requestId,
			originalStartKey = key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})
	)

	if options == nil or options.payload ~= false then
		local request: SharedRequestTypes.CompiledActionRequest = TestUtils.catalog.requestsById[actionId]

		local encoded: string = if options ~= nil and options.encoded ~= nil
			then options.encoded
			else assert(PayloadCodec.Encode(request.start, parameters))

		local admission: RequestTypes.ActionRequestAdmission = table.freeze({
			kind = "Start" :: "Start",
			incarnation = 1,
			requestId = requestId,
			originalStartRequestId = requestId,
			actor = actor,
			actionId = actionId,
			origin = origin,
			inputTimestamp = nil,
			requestKey = key,
			originalStartKey = key,
		})

		for observer in table.clone(fixture.payloads) do
			observer(table.freeze({ admission = admission, payload = request.start, encoded = encoded }))
		end
	end

	return { key = key, requestId = requestId }
end

function TestUtils.outcome(
	fixture: Port,
	actor: ActorTypes.ActorView,
	actionId: string,
	start: Start,
	status: "Accepted" | "Rejected" | "Unknown",
	sequenceId: number?,
	reason: string?
): ()
	local ordinal: number, observedAt: number = metadata(fixture)

	local fact: ActionTypes.ActionRequestOutcome = if status == "Accepted"
		then table.freeze({
			kind = "RequestOutcome" :: "RequestOutcome",
			operation = "Start" :: "Start",
			status = "Accepted" :: "Accepted",
			sequenceId = assert(sequenceId, "Accepted Start requires a sequenceId"),
			reason = reason,
			requestId = start.requestId,
			requestKey = start.key,
			actor = actor,
			actionId = actionId,
			origin = "Direct" :: "Direct",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})
		else table.freeze({
			kind = "RequestOutcome" :: "RequestOutcome",
			operation = "Start" :: "Start",
			status = status,
			sequenceId = nil,
			reason = reason,
			requestId = start.requestId,
			requestKey = start.key,
			actor = actor,
			actionId = actionId,
			origin = "Direct" :: "Direct",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})

	TestUtils.emit(fixture, fact)
end

function TestUtils.followUp(
	fixture: Port,
	actor: ActorTypes.ActorView,
	actionId: string,
	start: Start,
	operation: "Stop" | "Interrupt",
	status: "Admitted" | "Accepted" | "Rejected" | "Unknown",
	requestId: number,
	reason: string?
): ()
	local ordinal: number, observedAt: number = metadata(fixture)
	local key: string = "1:" .. requestId

	local fact: ActionTypes.ActionRequestEvent = if status == "Admitted"
		then table.freeze({
			kind = "RequestAdmitted" :: "RequestAdmitted",
			operation = operation,
			requestId = requestId,
			requestKey = key,
			inputOccurredAt = nil,
			actor = actor,
			actionId = actionId,
			origin = "Direct" :: "Direct",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})
		elseif status == "Accepted" then table.freeze({
			kind = "RequestOutcome" :: "RequestOutcome",
			operation = operation,
			status = "Accepted" :: "Accepted",
			sequenceId = nil,
			reason = reason,
			requestId = requestId,
			requestKey = key,
			actor = actor,
			actionId = actionId,
			origin = "Direct" :: "Direct",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})
		else table.freeze({
			kind = "RequestOutcome" :: "RequestOutcome",
			operation = operation,
			status = status,
			sequenceId = nil,
			reason = reason,
			requestId = requestId,
			requestKey = key,
			actor = actor,
			actionId = actionId,
			origin = "Direct" :: "Direct",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})

	TestUtils.emit(fixture, fact)
end

function TestUtils.transition(
	fixture: Port,
	actor: ActorTypes.ActorView,
	actionId: string,
	start: Start,
	transition: ActionTypes.LocalInputTransition,
	reason: string?
): ()
	local ordinal: number, observedAt: number = metadata(fixture)

	TestUtils.emit(
		fixture,
		table.freeze({
			kind = "InputTransition" :: "InputTransition",
			transition = transition,
			reason = reason,
			actor = actor,
			actionId = actionId,
			origin = "Input" :: "Input",
			originalStartRequestId = start.requestId,
			originalStartKey = start.key,
			eventOrdinal = ordinal,
			observedAt = observedAt,
		})
	)
end

function TestUtils.started(actions: ActorTypes.DomainViewOwner, actionId: string, sequenceId: number): ()
	actions:FireEvent("Started", table.freeze({ actionId = actionId, sequenceId = sequenceId }))
end

return TestUtils
