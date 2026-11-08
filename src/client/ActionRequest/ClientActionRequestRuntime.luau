--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local PayloadCodec = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Facts = require(script.Parent.utils.ActionRequestFacts)
local FollowUps = require(script.Parent.utils.ActionFollowUpQueue)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

-- Private bound on original Starts retained for follow-up authority.
local DEFAULT_MAX_ORIGINAL_STARTS: number = 64

local INTERRUPT_REASONS: { [string]: boolean } = {}

for _, reason: string in Constants.INTERRUPT_REASONS do
	INTERRUPT_REASONS[reason] = true
end

table.freeze(INTERRUPT_REASONS)

-- Retiring follow-up authority preserves unsettled Start result correlation.
type Original = {
	admission: Types.ActionRequestAdmission,
	request: ActionRequestTypes.CompiledActionRequest,
	settled: boolean,
	retired: boolean,
	decisions: number,
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
	facts: Facts.Owner,
	pendingFollowUps: FollowUps.Owner,
	disconnect: () -> (),
	disconnectCapacity: (() -> ())?,
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

local function hasFollowUps(request: ActionRequestTypes.CompiledActionRequest): boolean
	return request.stop ~= nil or request.allowInputInterrupt
end

function ClientActionRequestRuntime._removeOriginal(self: Runtime, requestId: number): ()
	if self.originals[requestId] ~= nil then
		self.originals[requestId] = nil
		self.originalCount -= 1
		self.pendingFollowUps.Remove(requestId)
	end
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

			if original.retired or not hasFollowUps(original.request) then
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

	self.facts.Stage({ outcome = outcome, original = admission.originalStartRequestId, ready = true })

	if self.commands.AfterEgress ~= nil then
		self.commands.AfterEgress(self.facts.Drain)
	else
		self.facts.Drain()
	end
end

function ClientActionRequestRuntime._send(
	self: Runtime,
	commandId: string,
	actor: ActorTypes.ActorView?,
	request: any,
	admit: (requestId: number) -> Types.ActionRequestAdmission,
	rollback: (requestId: number) -> (),
	committed: ((Types.ActionRequestAdmission) -> ())?
): (number?, string?)
	local admitted: Types.ActionRequestAdmission? = nil
	local fact: Facts.Fact? = nil

	local requestId: number?, reason: string? = self.commands.SendAdmitted(
		commandId,
		actor,
		request,
		function(id: number): boolean
			local reserved: Types.ActionRequestAdmission = admit(id)

			local staged: Facts.Fact =
				{ admission = reserved, original = reserved.originalStartRequestId, ready = false }

			admitted, fact = reserved, staged
			self.facts.Stage(staged)

			return true
		end,
		if committed ~= nil
			then function(): ()
				committed(assert(admitted, "Expected reserved request correlation"))
			end
			else nil
	)

	local staged: Facts.Fact? = fact

	if requestId == nil then
		local reserved: Types.ActionRequestAdmission? = admitted

		if reserved ~= nil then
			rollback(reserved.requestId)
		end

		if staged ~= nil then
			self.facts.Withdraw(staged)
		end

		return nil, reason or "CommandAdmissionRefused"
	end

	assert(staged ~= nil, "ActionRequestAdmissionMissing")

	if self.commands.AfterEgress ~= nil then
		self.commands.AfterEgress(function(): ()
			self.facts.Commit(staged)
		end)
	else
		self.facts.Commit(staged)
	end

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
			local key: unknown = table.freeze({})

			local admission: Types.ActionRequestAdmission = table.freeze({
				kind = "Start" :: Types.ActionRequestKind,
				incarnation = self.incarnation,
				requestId = requestId,
				originalStartRequestId = requestId,
				actor = actor,
				actionId = compiled.actionId,
				origin = selection.origin,
				inputTimestamp = selection.inputTimestamp,
				requestKey = key,
				originalStartKey = key,
			})

			self.originals[requestId] =
				{ admission = admission, request = compiled, settled = false, retired = false, decisions = 0 }

			self.originalCount += 1

			if selection.Reserve ~= nil then
				local reserved: boolean = Observers.Run(selection.Reserve, admission)

				if not reserved then
					self:_removeOriginal(requestId)
					error("ActionRequestCorrelationFailed", 0)
				end
			end

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
	request: any,
	committed: ((Types.ActionRequestAdmission) -> ())?
): (number?, string?)
	local start: Types.ActionRequestAdmission = original.admission

	if self.followUpCount >= self.maxOriginalStarts * 2 then
		return nil, "ActionRequestCapacityReached"
	end

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
			requestKey = table.freeze({}),
			originalStartKey = start.requestKey,
		})

		self.followUps[requestId] = admission
		self.followUpCount += 1

		return admission
	end, function(requestId: number): ()
		if self.followUps[requestId] ~= nil then
			self.followUps[requestId] = nil
			self.followUpCount -= 1
		end
	end, committed)
end

function ClientActionRequestRuntime.Stop(
	self: Runtime,
	originalStartRequestId: number,
	parameters: any?,
	automatic: boolean?,
	committed: ((Types.ActionRequestAdmission) -> ())?
): (number?, string?)
	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Original? = self.originals[originalStartRequestId]

	if original == nil or original.retired then
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

	local intent: Types.ActionFollowUpIntent = table.freeze({
		originalStartRequestId = originalStartRequestId,
		kind = "Stop" :: "Stop",
		OnAdmitted = committed,
		payload = payload,
	})

	local requestId: number?, reason: string? = self:_sendIntent(intent)

	if
		automatic
		and requestId == nil
		and FollowUps.IsPressure(reason)
		and self.originals[originalStartRequestId] == original
	then
		self.pendingFollowUps.Remember(intent)
	end

	return requestId, reason
end

function ClientActionRequestRuntime.Interrupt(
	self: Runtime,
	originalStartRequestId: number,
	reason: ActionRequestTypes.ActionInputInterruptReason,
	automatic: boolean?,
	committed: ((Types.ActionRequestAdmission) -> ())?
): (number?, string?)
	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Original? = self.originals[originalStartRequestId]

	if original == nil or original.retired then
		return nil, "ActionStartUnknown"
	elseif not original.request.allowInputInterrupt then
		return nil, "ActionInterruptNotAllowed"
	elseif type(reason) ~= "string" or not INTERRUPT_REASONS[reason] then
		return nil, "ActionInterruptReasonInvalid"
	end

	local intent: Types.ActionFollowUpIntent = table.freeze({
		originalStartRequestId = originalStartRequestId,
		kind = "Interrupt" :: "Interrupt",
		OnAdmitted = committed,
		reason = reason,
	})

	local requestId: number?, failure: string? = self:_sendIntent(intent)

	if
		automatic
		and requestId == nil
		and FollowUps.IsPressure(failure)
		and self.originals[originalStartRequestId] == original
	then
		self.pendingFollowUps.Remember(intent)
	end

	return requestId, failure
end

function ClientActionRequestRuntime.GetOriginalStart(self: Runtime, requestId: number): Types.ActionRequestAdmission?
	local original: Original? = self.originals[requestId]

	return if original ~= nil and not original.retired then original.admission else nil
end

function ClientActionRequestRuntime.Retire(self: Runtime, originalStartRequestId: number): ()
	local original: Original? = self.originals[originalStartRequestId]

	if original ~= nil then
		original.retired = true
		self.pendingFollowUps.Remove(originalStartRequestId)

		if original.settled then
			self:_removeOriginal(originalStartRequestId)
		end
	end
end

function ClientActionRequestRuntime._sendIntent(self: Runtime, intent: Types.ActionFollowUpIntent): (number?, string?)
	local original: Original? = self.originals[intent.originalStartRequestId]

	if self.destroyed or original == nil or original.retired then
		return nil, "ActionStartUnknown"
	end

	local prior: Types.ActionFollowUpIntent? = self.pendingFollowUps.Get(intent.originalStartRequestId)

	local requestId: number?, reason: string? = self:_followUp(
		intent.kind,
		original,
		if intent.kind == "Stop" then Constants.STOP_COMMAND_ID else Constants.INTERRUPT_COMMAND_ID,
		{
			originalStartRequestId = intent.originalStartRequestId,
			payload = intent.payload,
			reason = intent.reason,
		},
		intent.OnAdmitted
	)

	if requestId ~= nil then
		self.pendingFollowUps.Complete(intent.originalStartRequestId, prior)
	end

	return requestId, reason
end

function ClientActionRequestRuntime.ObserveAdmissions(
	self: Runtime,
	observer: (Types.ActionRequestAdmission) -> ()
): () -> ()
	return self.facts.ObserveAdmissions(observer)
end

function ClientActionRequestRuntime.ObserveOutcomes(
	self: Runtime,
	observer: (Types.ActionRequestOutcome) -> ()
): () -> ()
	return self.facts.ObserveOutcomes(observer)
end

function ClientActionRequestRuntime.StageDecision(self: Runtime, originalStartRequestId: number, callback: () -> ()): ()
	local original: Original? = self.originals[originalStartRequestId]

	if not self.destroyed and original ~= nil and original.decisions < 2 then
		original.decisions += 1
		self.facts.Stage({ original = originalStartRequestId, callback = callback, ready = true })

		if self.commands.AfterEgress ~= nil then
			self.commands.AfterEgress(self.facts.Drain)
		else
			self.facts.Drain()
		end
	end
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
	self.facts.Destroy()
	self.pendingFollowUps.Destroy()

	if self.disconnectCapacity ~= nil then
		self.disconnectCapacity()
	end

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
			facts = Facts.new(maximum * 12),
			pendingFollowUps = FollowUps.new(function(intent): (number?, string?)
				return self:_sendIntent(intent)
			end),
			disconnect = disconnect,
			destroyed = false,
		}

		self = setmetatable(state, ClientActionRequestRuntime)

		if options.commands.ObserveCapacity ~= nil then
			self.disconnectCapacity = options.commands.ObserveCapacity(self.pendingFollowUps.Drain)
		end

		return self :: Types.ClientActionRequestRuntime
	end,
}

return table.freeze(module)
