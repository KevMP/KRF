--!strict
local Types = require(script.Parent.types)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local State = require(script.Parent.utils.HintRuntimeState)

local facade: Types.HintRuntime = {
	OnHintReceived = State.OnHintReceived,
	Send = function(id: string, actor: PublicTypes.ActorView?, payload: any?): (boolean, string?)
		local runtime = State.Get()

		if runtime == nil then
			return false, "ClientNotReady"
		end

		return runtime:Send(id, actor, payload)
	end,
}

return table.freeze(facade)
