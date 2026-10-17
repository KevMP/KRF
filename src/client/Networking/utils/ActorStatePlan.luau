--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)

local ActorStatePlan = {}
-- Wrapper distinguishes successful Optional(nil) from failure.
export type Result = { read value: any }
export type Plan = {
	Snapshot: (any) -> (Result?, string?),
	Apply: (any, SharedNetworkingTypes.ActorPatch) -> (Result?, string?),
}

function ActorStatePlan.Compile(_schema: SharedNetworkingTypes.CompiledSchema): Plan
	return {
		Snapshot = function(_value: any): (Result?, string?)
			return nil, "N5NotImplemented"
		end,
		Apply = function(_previous: any, _patch: SharedNetworkingTypes.ActorPatch): (Result?, string?)
			return nil, "N5NotImplemented"
		end,
	}
end

return ActorStatePlan
