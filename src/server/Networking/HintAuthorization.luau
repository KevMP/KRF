--!strict
local Types = require(script.Parent.types)
local Context = require(script.Parent.utils.HintContext)
local HintAuthorization = {}

function HintAuthorization.AnyReadyClient(context: Types.HintContext, _payload: any): (boolean, string?)
	local allowed = Context.IsReady(context)

	return allowed, if allowed then nil else "ClientNotReady"
end

function HintAuthorization.OwnerActor(context: Types.HintContext, _payload: any): (boolean, string?)
	local allowed = Context.IsOwner(context)

	return allowed, if allowed then nil else "ActorNotOwned"
end

return table.freeze(HintAuthorization)
