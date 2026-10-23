--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local State = require(script.Parent.utils.CommandRuntimeState)

local facade: Types.CommandRuntime = {
	Send = function(commandId: string, actor: PublicTypes.ActorView?, request: any?): (number?, string?)
		local runtime: Types.ClientCommandRuntime? = State.Get()

		if runtime == nil then
			return nil, "ClientNotReady"
		end

		return runtime:Send(commandId, actor, request)
	end,
	OnCommandResult = State.OnCommandResult,
	OnCommandUncertain = State.OnCommandUncertain,
}

return table.freeze(facade)
