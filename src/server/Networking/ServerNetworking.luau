--!strict
local NetworkingTypes = require(script.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)

local ServerNetworking = {} :: NetworkingTypes.ServerNetworking

function ServerNetworking.Prepare(
	_catalog: ReplicationTypes.PreparedReplicationDomainCatalog
): (ProtocolTypes.PreparedProtocol?, string?)
	return nil, "N2NotImplemented"
end

function ServerNetworking.Publish(_protocol: ProtocolTypes.PreparedProtocol): (boolean, string?)
	return false, "N2NotImplemented"
end

function ServerNetworking._IsInitialized(): boolean
	return false
end

function ServerNetworking._ResetForTests(): () end

return ServerNetworking
