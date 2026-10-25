--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local State = require(script.Parent.utils.HintRuntimeState)

local facade: Types.HintRuntime = {
	SendTo = function(player: Player, id: string, actor: ActorTypes.Actor?, payload: any?): (boolean, string?)
		local runtime = State.Get()

		if runtime == nil then
			return false, "NetworkingNotInitialized"
		end

		return runtime:SendTo(player, id, actor, payload)
	end,
}

return table.freeze(facade)
