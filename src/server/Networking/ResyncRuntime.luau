--!strict
local Types = require(script.Parent.types)
local ResyncRuntime = {}

function ResyncRuntime.new(_dependencies: Types.ResyncDependencies, _options: Types.ResyncOptions): Types.ResyncRuntime
	return {
		Handle = function(_self: Types.ResyncRuntime, _player: Player, _payload: any): (boolean, string?)
			return false, "N5NotImplemented"
		end,
		Destroy = function(_self: Types.ResyncRuntime): () end,
	}
end

return ResyncRuntime
