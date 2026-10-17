--!strict
local Types = require(script.Parent.ResyncTypes)
local ResyncRuntime = {}

function ResyncRuntime.new(_dependencies: Types.Dependencies, _options: Types.Options): Types.Runtime
	return {
		Handle = function(_self: Types.Runtime, _player: Player, _payload: any): (boolean, string?)
			return false, "N5NotImplemented"
		end,
		Destroy = function(_self: Types.Runtime): () end,
	}
end

return ResyncRuntime
