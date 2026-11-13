--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local PayloadCodec = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)
local Registry = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Facts = require(script.Parent.utils.ActionRequestFacts)
local Correlation = require(script.Parent.utils.ActionRequestCorrelation)
local Dispatch = require(script.Parent.utils.ActionRequestDispatch)
local FollowUps = require(script.Parent.utils.ActionFollowUpQueue)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

-- Private bound on original Starts retained for follow-up authority.
local DEFAULT_MAX_ORIGINAL_STARTS: number = 64

local INTERRUPT_REASONS: { [string]: boolean } = {}

for _, reason: string in Constants.INTERRUPT_REASONS do
	INTERRUPT_REASONS[reason] = true
end

table.freeze(INTERRUPT_REASONS)

type State = {
	catalog: ActionRequestTypes.ActionRequestCatalog,
	incarnation: number,
	correlation: Correlation.Owner,
	dispatch: Dispatch.Owner,
	facts: Facts.Owner,
	pendingFollowUps: FollowUps.Owner,
	disconnect: () -> (),
	disconnectCapacity: (() -> ())?,
	disconnectExpirations: (() -> ())?,
	destroyed: boolean,
}

local ClientActionRequestRuntime = {}
ClientActionRequestRuntime.__index = ClientActionRequestRuntime

type Runtime = typeof(setmetatable({} :: State, ClientActionRequestRuntime))

function ClientActionRequestRuntime.Start(
	self: Runtime,
	selection: Types.ActionStartSelection,
	parameters: any?
): (number?, string?)
	Observers.CheckReentry()

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
	elseif not self.correlation.CanStart() then
		return nil, "ActionRequestCapacityReached"
	end

	local compiled: ActionRequestTypes.CompiledActionRequest = request

	return self.dispatch.Send(
		Constants.START_COMMAND_ID,
		actor,
		{ actionId = compiled.actionId, contractTag = compiled.contractTag, payload = payload },
		function(requestId: number): Types.ActionRequestAdmission
			local admission: Types.ActionRequestAdmission =
				self.correlation.ReserveStart(requestId, actor, selection, compiled)

			if selection.Reserve ~= nil then
				local reserved: boolean = Observers.Run(selection.Reserve, admission)

				if not reserved then
					self.correlation.RemoveStart(requestId)
					error("ActionRequestCorrelationFailed", 0)
				end
			end

			return admission
		end,
		function(requestId: number): ()
			self.correlation.RemoveStart(requestId)
		end
	)
end

function ClientActionRequestRuntime.Stop(
	self: Runtime,
	originalStartRequestId: number,
	parameters: any?,
	automatic: boolean?,
	committed: ((Types.ActionRequestAdmission) -> ())?
): (number?, string?)
	Observers.CheckReentry()

	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Correlation.Start? = self.correlation.GetStart(originalStartRequestId)

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
		and self.correlation.ContainsStart(originalStartRequestId, original)
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
	Observers.CheckReentry()

	if self.destroyed then
		return nil, "ActionRequestRuntimeDestroyed"
	end

	local original: Correlation.Start? = self.correlation.GetStart(originalStartRequestId)

	if original == nil then
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
		and self.correlation.ContainsStart(originalStartRequestId, original)
	then
		self.pendingFollowUps.Remember(intent)
	end

	return requestId, failure
end

function ClientActionRequestRuntime.GetOriginalStart(self: Runtime, requestId: number): Types.ActionRequestAdmission?
	local original: Correlation.Start? = self.correlation.GetStart(requestId)

	return if original ~= nil then original.admission else nil
end

function ClientActionRequestRuntime.Retire(self: Runtime, originalStartRequestId: number): ()
	self.correlation.Retire(originalStartRequestId)
end

function ClientActionRequestRuntime._sendIntent(self: Runtime, intent: Types.ActionFollowUpIntent): (number?, string?)
	local original: Correlation.Start? = self.correlation.GetStart(intent.originalStartRequestId)

	if self.destroyed or original == nil then
		return nil, "ActionStartUnknown"
	elseif not self.correlation.CanFollowUp() then
		return nil, "ActionRequestCapacityReached"
	end

	local prior: Types.ActionFollowUpIntent? = self.pendingFollowUps.Get(intent.originalStartRequestId)

	local requestId: number?, reason: string? = self.dispatch.Send(
		if intent.kind == "Stop" then Constants.STOP_COMMAND_ID else Constants.INTERRUPT_COMMAND_ID,
		nil,
		{
			originalStartRequestId = intent.originalStartRequestId,
			payload = intent.payload,
			reason = intent.reason,
		},
		function(id: number): Types.ActionRequestAdmission
			return self.correlation.ReserveFollowUp(id, intent.kind, original.admission)
		end,
		self.correlation.RemoveFollowUp,
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

function ClientActionRequestRuntime.StageDecision(
	self: Runtime,
	original: Types.ActionRequestAdmission,
	callback: () -> ()
): ()
	-- I6 owns this captured local decision, even if a synchronous definitive
	-- result has already retired I5's follow-up/correlation record.
	if not self.destroyed and original.incarnation == self.incarnation and original.kind == "Start" then
		self.dispatch.Stage({ original = original.requestId, callback = callback, ready = true })
	end
end

function ClientActionRequestRuntime._GetRetainedCountForTests(self: Runtime): number
	return self.correlation.Count()
end

function ClientActionRequestRuntime.AfterObservations(self: Runtime, callback: () -> ()): ()
	self.dispatch.AfterObservations(callback)
end

function ClientActionRequestRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self.disconnect()
	self.correlation.Destroy()
	self.facts.Destroy()
	self.pendingFollowUps.Destroy()

	if self.disconnectCapacity ~= nil then
		self.disconnectCapacity()
	end

	if self.disconnectExpirations ~= nil then
		self.disconnectExpirations()
	end
end

local module: Types.ClientActionRequestRuntimeModule = {
	new = function(
		catalog: ActionRequestTypes.ActionRequestCatalog,
		options: Types.ClientActionRequestOptions
	): Types.ClientActionRequestRuntime
		assert(
			options.incarnation >= 1 and options.incarnation <= 9007199254740991 and options.incarnation % 1 == 0,
			"ActionRequestIncarnationExhausted"
		)

		local maximum: number = options.maxOriginalStarts or DEFAULT_MAX_ORIGINAL_STARTS
		assert(maximum >= 1 and maximum % 1 == 0 and maximum < math.huge, "InvalidActionRequestLimit")

		local self: Runtime

		-- N9 only delivers outcomes for requests this runtime later sends, never during subscription.
		local disconnect: () -> () = options.commands.ObserveOutcomes(
			function(result: NetworkingTypes.CommandResult): ()
				if not self.destroyed then
					local outcome: Types.ActionRequestOutcome? = self.correlation.Receive(result)

					if outcome ~= nil then
						self.dispatch.Stage({
							outcome = outcome,
							original = outcome.admission.originalStartRequestId,
							ready = true,
						})
					end
				end
			end
		)

		local facts: Facts.Owner = Facts.new(maximum * 12)

		local pendingFollowUps: FollowUps.Owner = FollowUps.new(function(intent): (number?, string?)
			return self:_sendIntent(intent)
		end)

		local state: State = {
			catalog = catalog,
			incarnation = options.incarnation,
			correlation = Correlation.new(options.incarnation, maximum, pendingFollowUps.Remove),
			dispatch = Dispatch.new(options.commands, facts),
			facts = facts,
			pendingFollowUps = pendingFollowUps,
			disconnect = disconnect,
			destroyed = false,
		}

		self = setmetatable(state, ClientActionRequestRuntime)

		local subscribed: boolean, failure: any = pcall(function(): ()
			if options.commands.ObserveCapacity ~= nil then
				self.disconnectCapacity = options.commands.ObserveCapacity(self.pendingFollowUps.Drain)
			end

			if options.commands.ObserveExpirations ~= nil then
				self.disconnectExpirations = options.commands.ObserveExpirations(
					function(id: number, commandId: string): ()
						if not self.destroyed then
							self.correlation.Expire(id, commandId)
						end
					end
				)
			end
		end)

		if not subscribed then
			self:Destroy()
			error(failure, 0)
		end

		return self :: Types.ClientActionRequestRuntime
	end,
}

return table.freeze(module)
