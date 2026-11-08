--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local PayloadCodec = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

-- Private bound on original Starts retained for follow-up authority.
local DEFAULT_MAX_ORIGINAL_STARTS: number = 64

-- Private bound on framework observers of each I5 fact stream.
local MAX_OBSERVERS: number = 16

local INTERRUPT_REASONS: { [string]: boolean } = {}

for _, reason: string in Constants.INTERRUPT_REASONS do
	INTERRUPT_REASONS[reason] = true
end

table.freeze(INTERRUPT_REASONS)

-- An admitted Start retained until a definitive rejection, a release-free acceptance,
-- or I6 retiring the activation.
type Original = {
	admission: Types.ActionRequestAdmission,
	request: ActionRequestTypes.CompiledActionRequest,
	settled: boolean,
}

-- One observer handoff in causal order. An admission is ready once its send call
-- returns; an outcome that a reentrant transport delivered earlier waits behind it.
-- At most one admission and two outcomes exist per retained request, so the queue
-- is bounded by the original and follow-up records.
type Fact = {
	admission: Types.ActionRequestAdmission?,
	outcome: Types.ActionRequestOutcome?,
	ready: boolean,
}

type State = {
	catalog: ActionRequestTypes.ActionRequestCatalog,
	commands: Types.ActionRequestCommandPort,
	incarnation: number,
	maxOriginalStarts: number,
	originals: { [number]: Original },
	originalCount: number,
	-- Stop and Interrupt requests awaiting their first outcome.
	followUps: { [number]: Types.ActionRequestAdmission },
	followUpCount: number,
	admissionObservers: Observers.Registry<(Types.ActionRequestAdmission) -> ()>,
	outcomeObservers: Observers.Registry<(Types.ActionRequestOutcome) -> ()>,
	facts: { Fact },
	draining: boolean,
	disconnect: () -> (),
	destroyed: boolean,
}

local ClientActionRequestRuntime = {}
ClientActionRequestRuntime.__index = ClientActionRequestRuntime

type Runtime = typeof(setmetatable({} :: State, ClientActionRequestRuntime))

local COMMAND_KINDS: { [string]: Types.ActionRequestKind } = {
	[Constants.START_COMMAND_ID] = "Start",
	[Constants.STOP_COMMAND_ID] = "Stop",
	[Constants.INTERRUPT_COMMAND_ID] = "Interrupt",
}

table.freeze(COMMAND_KINDS)

-- Framework observers are bounded and non-yielding; a fault or yield never reaches egress.
local function notify<T>(observers: Observers.Registry<(T) -> ()>, value: T): ()
	for _, entry: Observers.Entry<(T) -> ()> in observers.Snapshot() do
		if entry.active then
			Observers.Run(entry.callback, value)
		end
	end
end

local function hasFollowUps(request: ActionRequestTypes.CompiledActionRequest): boolean
	return request.stop ~= nil or request.allowInputInterrupt
end

function ClientActionRequestRuntime._removeOriginal(self: Runtime, requestId: number): ()
	if self.originals[requestId] ~= nil then
		self.originals[requestId] = nil
		self.originalCount -= 1
	end
end

-- Publishes ready facts from the head. A reentrant caller only enqueues; the
-- outermost drain delivers, so observers always see Admission before Outcome.
function ClientActionRequestRuntime._drain(self: Runtime): ()
	if self.draining then
		return
	end

	self.draining = true

	while not self.destroyed do
		local head: Fact? = self.facts[1]

		if head == nil or not head.ready then
			break
		end

		table.remove(self.facts, 1)

		if head.admission ~= nil then
			notify(self.admissionObservers, head.admission)
		elseif head.outcome ~= nil then
			notify(self.outcomeObservers, head.outcome)
		end
	end

	self.draining = false
end

-- Correlation is installed before any outcome observer can run.
function ClientActionRequestRuntime._receive(self: Runtime, result: NetworkingTypes.CommandResult): ()
	local kind: Types.ActionRequestKind? = COMMAND_KINDS[result.commandId]

	if self.destroyed or kind == nil then
		return
	end

	local admission: Types.ActionRequestAdmission
	local sequenceId: number? = nil

	if kind == "Start" then
		local original: Original? = self.originals[result.requestId]

		if original == nil or original.settled then
			return
		end

		admission = original.admission

		if result.status == "Accepted" then
			original.settled = true
			sequenceId = if type(result.result) == "table" then result.result.sequenceId else nil

			if not hasFollowUps(original.request) then
				self:_removeOriginal(result.requestId)
			end
		elseif result.status == "Rejected" then
			self:_removeOriginal(result.requestId)
		end
	else
		local followUp: Types.ActionRequestAdmission? = self.followUps[result.requestId]

		if followUp == nil or followUp.kind ~= kind then
			return
		end

		-- Unknown is final for a follow-up: I5 never retries or escalates it.
		self.followUps[result.requestId] = nil
		self.followUpCount -= 1
		admission = followUp
	end

	local outcome: Types.ActionRequestOutcome = table.freeze({
		admission = admission,
		status = result.status,
		sequenceId = sequenceId,
		reason = result.reason,
	})

	table.insert(self.facts, { outcome = outcome, ready = true })
	self:_drain()
end

function ClientActionRequestRuntime._send(
	self: Runtime,
	commandId: string,
	actor: ActorTypes.ActorView?,
	request: any,
	admit: (requestId: number) -> Types.ActionRequestAdmission,
	rollback: (requestId: number) -> ()
): (number?, string?)
	local admitted: Types.ActionRequestAdmission? = nil
	local fact: Fact? = nil

	local requestId: number?, reason: string? = self.commands.SendAdmitted(
		commandId,
		actor,
		request,
		function(id: number): boolean
			local reserved: Types.ActionRequestAdmission = admit(id)
			local staged: Fact = { admission = reserved, ready = false }
			admitted, fact = reserved, staged
			table.insert(self.facts, staged)

			return true
		end
	)

	local staged: Fact? = fact

	if requestId == nil then
		local reserved: Types.ActionRequestAdmission? = admitted

		if reserved ~= nil then
			rollback(reserved.requestId)
		end

		local index: number? = if staged ~= nil then table.find(self.facts, staged) else nil

		if index ~= nil then
			table.remove(self.facts, index)
		end

		-- The withdrawn admission may have been holding later ready facts.
		self:_drain()

		return nil, reason or "CommandAdmissionRefused"
	end

	assert(staged ~= nil, "ActionRequestAdmissionMissing")
	staged.ready = true
	self:_drain()

	return requestId, nil
end

function ClientActionRequestRuntime.Start(
	self: Runtime,
	selection: Types.ActionStartSelection,
	parameters: any?
): (number?, string?)
	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local request: ActionRequestTypes.CompiledActionRequest? = self.catalog.requestsById[selection.actionId]

	if request == nil then
		return nil, "ActionRequestUnregistered"
	end

	local payload: string?, payloadReason: string? = PayloadCodec.Encode(request.start, parameters)

	if payload == nil then
		return nil, payloadReason
	end

	local actor: ActorTypes.ActorView = selection.actor

	if not Registry.IsCurrent(actor) or not actor:IsAvailable() then
		return nil, "ActorViewUnavailable"
	elseif self.originalCount >= self.maxOriginalStarts then
		return nil, "ActionRequestCapacityReached"
	end

	local compiled: ActionRequestTypes.CompiledActionRequest = request

	return self:_send(
		Constants.START_COMMAND_ID,
		actor,
		{ actionId = compiled.actionId, contractTag = compiled.contractTag, payload = payload },
		function(requestId: number): Types.ActionRequestAdmission
			local admission: Types.ActionRequestAdmission = table.freeze({
				kind = "Start" :: Types.ActionRequestKind,
				incarnation = self.incarnation,
				requestId = requestId,
				originalStartRequestId = requestId,
				actor = actor,
				actionId = compiled.actionId,
				origin = selection.origin,
				inputTimestamp = selection.inputTimestamp,
			})

			self.originals[requestId] = { admission = admission, request = compiled, settled = false }
			self.originalCount += 1

			return admission
		end,
		function(requestId: number): ()
			self:_removeOriginal(requestId)
		end
	)
end

function ClientActionRequestRuntime._followUp(
	self: Runtime,
	kind: Types.ActionRequestKind,
	original: Original,
	commandId: string,
	request: any
): (number?, string?)
	local start: Types.ActionRequestAdmission = original.admission

	return self:_send(commandId, nil, request, function(requestId: number): Types.ActionRequestAdmission
		local admission: Types.ActionRequestAdmission = table.freeze({
			kind = kind,
			incarnation = self.incarnation,
			requestId = requestId,
			originalStartRequestId = start.requestId,
			actor = start.actor,
			actionId = start.actionId,
			origin = start.origin,
			inputTimestamp = nil,
		})

		self.followUps[requestId] = admission
		self.followUpCount += 1

		return admission
	end, function(requestId: number): ()
		if self.followUps[requestId] ~= nil then
			self.followUps[requestId] = nil
			self.followUpCount -= 1
		end
	end)
end

function ClientActionRequestRuntime.Stop(
	self: Runtime,
	originalStartRequestId: number,
	parameters: any?
): (number?, string?)
	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Original? = self.originals[originalStartRequestId]

	if original == nil then
		return nil, "ActionStartUnknown"
	end

	local stop: ActionRequestTypes.CompiledActionPayload? = original.request.stop

	if stop == nil then
		return nil, "ActionStopUnavailable"
	end

	local payload: string?, payloadReason: string? = PayloadCodec.Encode(stop, parameters)

	if payload == nil then
		return nil, payloadReason
	end

	return self:_followUp(
		"Stop",
		original,
		Constants.STOP_COMMAND_ID,
		{ originalStartRequestId = originalStartRequestId, payload = payload }
	)
end

function ClientActionRequestRuntime.Interrupt(
	self: Runtime,
	originalStartRequestId: number,
	reason: ActionRequestTypes.ActionInputInterruptReason
): (number?, string?)
	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Original? = self.originals[originalStartRequestId]

	if original == nil then
		return nil, "ActionStartUnknown"
	elseif not original.request.allowInputInterrupt then
		return nil, "ActionInterruptNotAllowed"
	elseif type(reason) ~= "string" or not INTERRUPT_REASONS[reason] then
		return nil, "ActionInterruptReasonInvalid"
	end

	return self:_followUp(
		"Interrupt",
		original,
		Constants.INTERRUPT_COMMAND_ID,
		{ originalStartRequestId = originalStartRequestId, reason = reason }
	)
end

function ClientActionRequestRuntime.GetOriginalStart(self: Runtime, requestId: number): Types.ActionRequestAdmission?
	local original: Original? = self.originals[requestId]

	return if original ~= nil then original.admission else nil
end

function ClientActionRequestRuntime.Retire(self: Runtime, originalStartRequestId: number): ()
	self:_removeOriginal(originalStartRequestId)
end

function ClientActionRequestRuntime.ObserveAdmissions(
	self: Runtime,
	observer: (Types.ActionRequestAdmission) -> ()
): () -> ()
	-- A destroyed runtime publishes nothing further, so a late observer is inert.
	if self.destroyed then
		return function(): () end
	end

	return self.admissionObservers.Add(observer)
end

function ClientActionRequestRuntime.ObserveOutcomes(
	self: Runtime,
	observer: (Types.ActionRequestOutcome) -> ()
): () -> ()
	-- A destroyed runtime publishes nothing further, so a late observer is inert.
	if self.destroyed then
		return function(): () end
	end

	return self.outcomeObservers.Add(observer)
end

function ClientActionRequestRuntime._GetRetainedCountForTests(self: Runtime): number
	return self.originalCount + self.followUpCount
end

function ClientActionRequestRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self.disconnect()
	table.clear(self.originals)
	table.clear(self.followUps)
	table.clear(self.facts)
	self.admissionObservers.Destroy()
	self.outcomeObservers.Destroy()
	self.originalCount = 0
	self.followUpCount = 0
end

local module: Types.ClientActionRequestRuntimeModule = {
	new = function(
		catalog: ActionRequestTypes.ActionRequestCatalog,
		options: Types.ClientActionRequestOptions
	): Types.ClientActionRequestRuntime
		local maximum: number = options.maxOriginalStarts or DEFAULT_MAX_ORIGINAL_STARTS
		assert(maximum >= 1 and maximum % 1 == 0 and maximum < math.huge, "InvalidActionRequestLimit")

		local self: Runtime

		-- N9 only delivers outcomes for requests this runtime later sends, never during subscription.
		local disconnect: () -> () = options.commands.ObserveOutcomes(
			function(result: NetworkingTypes.CommandResult): ()
				self:_receive(result)
			end
		)

		local state: State = {
			catalog = catalog,
			commands = options.commands,
			incarnation = options.incarnation,
			maxOriginalStarts = maximum,
			originals = {},
			originalCount = 0,
			followUps = {},
			followUpCount = 0,
			admissionObservers = Observers.new(MAX_OBSERVERS, "ActionRequestObserverLimitExceeded") :: Observers.Registry<(Types.ActionRequestAdmission) -> ()>,
			outcomeObservers = Observers.new(MAX_OBSERVERS, "ActionRequestObserverLimitExceeded") :: Observers.Registry<(Types.ActionRequestOutcome) -> ()>,
			facts = {},
			draining = false,
			disconnect = disconnect,
			destroyed = false,
		}

		self = setmetatable(state, ClientActionRequestRuntime)

		return self :: Types.ClientActionRequestRuntime
	end,
}

return table.freeze(module)
