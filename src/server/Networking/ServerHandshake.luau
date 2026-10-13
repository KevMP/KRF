--!strict
local NetworkingTypes = require(script.Parent.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)

local ServerHandshake = {} :: NetworkingTypes.ServerHandshakeModule

function ServerHandshake.new(
	_protocol: ProtocolTypes.PreparedProtocol,
	_dependencies: NetworkingTypes.HandshakeDependencies
): NetworkingTypes.ServerHandshake
	error("N2NotImplemented", 2)
end

return ServerHandshake
