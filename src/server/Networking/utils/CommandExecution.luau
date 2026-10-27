--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Context = require(script.Parent.CommandContext)
local CommandDiagnostics = require(script.Parent.CommandDiagnostics)
local History = require(script.Parent.CommandOutcomeHistory)

type Dependencies = {
	awareness: Types.ActorAwarenessRuntime,
	IsClientReady: (Player) -> boolean,
	ReportFault: (Player, string) -> (),
	CloseConnection: (Player, string) -> (),
}

local Execution = {}
Execution.__index = Execution

type State = {
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	dependencies: Dependencies,
}

export type Runtime = typeof(setmetatable({} :: State, Execution))

function Execution.new(
	catalog: Types.PreparedCommandCatalog,
	protocol: SharedTypes.ClientProtocol,
	codec: SharedTypes.CommandCodec,
	dependencies: Dependencies
): Runtime
	return setmetatable(
		{ catalog = catalog, protocol = protocol, codec = codec, dependencies = dependencies },
		Execution
	)
end

local function invoke(callback: (...any) -> ...any, ...: any): (boolean, any, any)
	local callbackThread: thread = coroutine.create(callback)
	local completed: boolean, first: any, second: any = coroutine.resume(callbackThread, ...)

	if coroutine.status(callbackThread) ~= "dead" then
		pcall(task.cancel, callbackThread)
		pcall(coroutine.close, callbackThread)

		return false, "CommandCallbackYielded", nil
	end

	return completed, first, second
end

local function reasonValid(reason: any): boolean
	return type(reason) == "string" and #reason > 0 and #reason <= Constants.MAX_REASON_BYTES
end

function Execution._invoke(
	self: Runtime,
	player: Player,
	request: SharedTypes.CommandRequest,
	command: SharedTypes.ClientCommand,
	definition: Types.LoadedCommandDefinition,
	history: History.Runtime,
	diagnostics: SharedTypes.DiagnosticCollector?,
	current: () -> boolean
): (SharedTypes.CommandResult, ActorTypes.Actor?, string?)
	local actor: ActorTypes.Actor? = nil
	local targetReason: string? = nil

	if request.targetHandle ~= nil then
		actor, targetReason = self.dependencies.awareness:ResolveActor(player, request.targetHandle)
	end

	local outcome: SharedTypes.CommandResult = {
		commandCode = request.commandCode,
		requestId = request.requestId,
		status = "Rejected",
		reason = "ActorUnavailable",
	}

	local fault: string? = nil

	if request.targetHandle == nil or actor ~= nil then
		local context: Types.CommandContext, closeContext: () -> () = Context.new(
			player,
			actor,
			request.requestId,
			command.id,
			function(id: number): Types.CommandOutcome?
				if not current() or type(id) ~= "number" or id <= 0 or id >= request.requestId or id % 1 ~= 0 then
					return nil
				end

				return history:Get(id)
			end,
			{
				ready = function(): boolean
					return current() and self.dependencies.IsClientReady(player)
				end,
				owns = function(): boolean
					return actor ~= nil
						and self.dependencies.awareness:GetPlayerForActor(actor) == player
						and self.dependencies.awareness:GetActorForPlayer(player) == actor
				end,
			}
		)

		local authorized: boolean, allowed: any, denial: any = invoke(definition.authorize, context, request.request)

		if
			not authorized
			or type(allowed) ~= "boolean"
			or (allowed == false and not reasonValid(denial))
			or (allowed == true and denial ~= nil)
		then
			fault = "CommandAuthorizationFault"
		elseif not allowed then
			outcome =
				{ commandCode = command.code, requestId = request.requestId, status = "Rejected", reason = denial }
		elseif current() then
			Metrics.Count(diagnostics, "commandsExecuted", 1)
			local handled: boolean, result: any = invoke(definition.handle, context, request.request)

			if not handled or type(result) ~= "table" or type(rawget(result, "accepted")) ~= "boolean" then
				fault = "CommandHandlerFault"
			else
				for key in next, result do
					if key ~= "accepted" and key ~= "result" and key ~= "reason" then
						fault = "CommandHandlerFault"
					end
				end

				outcome = {
					commandCode = command.code,
					requestId = request.requestId,
					status = if result.accepted then "Accepted" else "Rejected",
					result = rawget(result, "result"),
					reason = rawget(result, "reason") :: any,
				}
			end
		end

		closeContext()
	elseif targetReason ~= nil then
		-- Safely correlated valid envelopes may receive a bounded pre-effect rejection.
		outcome = {
			commandCode = command.code,
			requestId = request.requestId,
			status = "Rejected",
			reason = "ActorUnavailable",
		}
	end

	return outcome, actor, fault
end

function Execution.Execute(
	self: Runtime,
	player: Player,
	history: History.Runtime,
	diagnostics: SharedTypes.DiagnosticCollector?,
	current: () -> boolean,
	request: SharedTypes.CommandRequest,
	reservation: Types.CommandReservation,
	observation: CommandDiagnostics.Observation
): ()
	local commands: { [number]: SharedTypes.ClientCommand } = self.protocol.commandsByCode or {}
	local command: SharedTypes.ClientCommand = commands[request.commandCode]
	local definition: Types.LoadedCommandDefinition = self.catalog.definitionsById[command.id]

	local outcome: SharedTypes.CommandResult, actor: ActorTypes.Actor?, fault: string? =
		self:_invoke(player, request, command, definition, history, diagnostics, current)

	if fault ~= nil then
		CommandDiagnostics.Fault(observation)
	end

	if not current() or not self.dependencies.IsClientReady(player) then
		CommandDiagnostics.Uncertain(observation)
		reservation.Cancel()

		return
	end

	local encoded: buffer? = nil

	if fault == nil then
		encoded = self.codec.EncodeResult(outcome)

		if encoded == nil then
			fault = "CommandResultFault"
			CommandDiagnostics.Fault(observation)
		end
	end

	if fault ~= nil then
		CommandDiagnostics.Uncertain(observation)
		outcome = { commandCode = command.code, requestId = request.requestId, status = "Unknown", reason = fault }
		encoded = self.codec.EncodeResult(outcome)
		pcall(self.dependencies.ReportFault, player, fault)
	end

	if not current() then
		reservation.Cancel()

		return
	end

	if encoded == nil then
		reservation.Cancel()
		self.dependencies.CloseConnection(player, "CommandEgressFault")

		return
	end

	-- Round-trip through the compiled result schema before retaining any author data.
	local owned: SharedTypes.CommandResult? = self.codec.DecodeResult(encoded)
	assert(owned ~= nil, "Encoded command result must decode")

	if owned.status ~= "Unknown" then
		Metrics.Count(diagnostics, if owned.status == "Accepted" then "commandsAccepted" else "commandsRejected", 1)
	end

	local retained: Types.CommandOutcome = table.freeze({
		requestId = request.requestId,
		commandId = command.id,
		targetActor = actor,
		status = owned.status,
		result = owned.result,
		reason = owned.reason,
	})

	history:Retain(retained, buffer.len(encoded) + #command.id + 24)

	if not reservation.Commit(encoded) then
		CommandDiagnostics.Fault(observation)
		CommandDiagnostics.Uncertain(observation)
		self.dependencies.CloseConnection(player, "CommandEgressFault")
	end
end

return Execution
