--!strict
local Types = require(script.Parent.types)
local Context = require(script.Parent.utils.CommandContext)

local CommandAuthorization = {}

function CommandAuthorization.AnyReadyClient(context: Types.CommandContext, _request: any): (boolean, string?)
	local allowed: boolean = Context.IsReady(context)

	return allowed, if allowed then nil else "ClientNotReady"
end

function CommandAuthorization.OwnerActor(context: Types.CommandContext, _request: any): (boolean, string?)
	local allowed: boolean = Context.IsOwner(context)

	return allowed, if allowed then nil else "ActorNotOwned"
end

return table.freeze(CommandAuthorization)
