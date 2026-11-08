--!strict
local Types = require(script.Parent.Parent.types)
local Activations = require(script.Parent.ActionInputActivations)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

local Parameters = {}

function Parameters.Context(
	identity: Activations.IdentitySnapshot,
	original: number?,
	resolved: any?
): Types.ActionInputContext
	return table.freeze({
		actor = identity.actor,
		actionId = identity.actionId,
		routeKey = identity.key,
		input = identity.hold,
		originalStartRequestId = original,
		resolvedParameters = resolved,
	})
end

function Parameters.Produce(
	callback: ((Types.ActionInputContext) -> any?)?,
	context: Types.ActionInputContext,
	fallback: any?
): (boolean, any, string?)
	if callback == nil then
		return true, fallback, nil
	end

	local completed: boolean, failure: string?, value: any = Observers.Run(callback, context)

	return completed,
		if completed then value else nil,
		if completed
			then nil
			else (if failure == "Yielded" then "ActionInputProducerYielded" else "ActionInputProducerFailed")
end

function Parameters.IsEncodingFailure(reason: string?): boolean
	return reason == "ActionPayloadInvalid" or reason == "ActionPayloadUnexpected" or reason == "ActionPayloadTooLarge"
end

return Parameters
