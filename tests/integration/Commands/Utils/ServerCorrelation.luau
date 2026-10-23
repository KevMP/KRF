--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local Schema = require(KRF.shared.Networking.Schema)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
local Scenario = {}

local function controller(actor: ActorTypes.Actor?): ActionTypes.ActionController
	assert(actor ~= nil, "Expected resolved Actor")

	local actions: ActionTypes.ActionController? =
		actor:GetController("ActionController") :: ActionTypes.ActionController?

	assert(actions ~= nil, "Expected normal built-in ActionController")

	return actions
end

Scenario.Actions = {
	function(): ActionTypes.ActionDefinition
		return {
			id = "Native.Interrupt",
			autoGrant = true,
			visibility = "ClientVisible",
			onStart = function(context: ActionTypes.ActionExecutionContext): ()
				context:Interrupt("Private.NativeReason")
			end,
		}
	end,
	function(): ActionTypes.ActionDefinition
		return {
			id = "Native.Keep",
			autoGrant = true,
			visibility = "ClientVisible",
			onStopRequested = function(context: ActionTypes.ActionExecutionContext): ()
				context:End()
			end,
		}
	end,
	function(): ActionTypes.ActionDefinition
		return {
			id = "Native.Pulse",
			autoGrant = true,
			visibility = "ClientVisible",
			onStart = function(context: ActionTypes.ActionExecutionContext): ()
				context:End()
			end,
		}
	end,
}

function Scenario.Commands(actors: { [Player]: ActorTypes.Actor }): { Types.CommandDefinition }
	return {
		{
			id = "Game.Interrupt",
			target = "Actor",
			authorize = Authorization.OwnerActor,
			result = Schema.Struct({ sequenceId = Schema.U32 }),
			handle = function(context: Types.CommandContext): Types.CommandHandlerResult
				local interrupted: ActionTypes.ActionRequestResult =
					controller(context.actor):RequestAction("Native.Interrupt")

				assert(interrupted.accepted, "Expected synchronous start/interruption")

				return { accepted = true, result = { sequenceId = interrupted.sequenceId } }
			end,
		},
		{
			id = "Game.Begin",
			target = "Actor",
			authorize = Authorization.OwnerActor,
			result = Schema.Struct({ sequenceId = Schema.U32, pulseSequence = Schema.U32 }),
			handle = function(context: Types.CommandContext): Types.CommandHandlerResult
				local started: ActionTypes.ActionRequestResult = controller(context.actor):RequestAction("Native.Keep")
				assert(started.accepted, "Expected accepted owned activation")
				local other: ActorTypes.Actor? = nil

				for player: Player, actor: ActorTypes.Actor in actors do
					if player ~= context.player then
						other = actor
					end
				end

				local pulse: ActionTypes.ActionRequestResult = controller(other):RequestAction("Native.Pulse")
				assert(pulse.accepted, "Expected cross-Actor transient lifecycle")

				return {
					accepted = true,
					result = { sequenceId = started.sequenceId, pulseSequence = pulse.sequenceId },
				}
			end,
		},
		{
			id = "Game.Pulse",
			target = "Actor",
			authorize = Authorization.OwnerActor,
			result = Schema.Struct({ sequenceId = Schema.U32 }),
			handle = function(context: Types.CommandContext): Types.CommandHandlerResult
				local pulse: ActionTypes.ActionRequestResult = controller(context.actor):RequestAction("Native.Pulse")
				assert(pulse.accepted, "Expected start/end during one command")

				return { accepted = true, result = { sequenceId = pulse.sequenceId } }
			end,
		},
		{
			id = "Game.Follow",
			target = "Actor",
			authorize = Authorization.OwnerActor,
			request = Schema.Struct({ priorRequestId = Schema.U32 }),
			handle = function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
				local prior: Types.CommandOutcome? = context:GetPriorOutcome(request.priorRequestId)

				if
					prior == nil
					or prior.status ~= "Accepted"
					or prior.commandId ~= "Game.Begin"
					or prior.targetActor ~= context.actor
				then
					return { accepted = false, reason = "PriorUnavailable" }
				end

				local stopped: boolean = controller(context.actor):RequestStop(prior.result.sequenceId)
				assert(stopped, "Expected follow-up to use retained sequence identity")

				return { accepted = true }
			end,
		},
	}
end

return Scenario
