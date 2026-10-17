--!strict
local SchemaTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

local ActorStatePlan = {}
-- Wrapper distinguishes successful Optional(nil) from failure.
export type Result = { read value: any }
export type Plan = {
	Snapshot: (any) -> (Result?, string?),
	Apply: (any, WireTypes.Patch) -> (Result?, string?),
}

function ActorStatePlan.Compile(_schema: SchemaTypes.CompiledSchema): Plan
	return {
		Snapshot = function(_value: any): (Result?, string?)
			return nil, "N5NotImplemented"
		end,
		Apply = function(_previous: any, _patch: WireTypes.Patch): (Result?, string?)
			return nil, "N5NotImplemented"
		end,
	}
end

return ActorStatePlan
