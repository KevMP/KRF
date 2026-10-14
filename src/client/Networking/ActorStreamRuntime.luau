--!strict
local Types = require(script.Parent.ActorStreamTypes)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

local ActorStreamRuntime = {} :: Types.RuntimeModule

function ActorStreamRuntime.new(
	_codec: WireTypes.Codec,
	_consumer: Types.Consumer?,
	_discovery: Types.Discovery,
	_options: Types.Options
): Types.Runtime
	error("N4NotImplemented:ActorStreamRuntime.new")
end

return ActorStreamRuntime
