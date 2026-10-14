--!strict
local Types = require(script.Parent.AwarenessTypes)
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)

local ActorAwarenessRuntime = {} :: Types.RuntimeModule

function ActorAwarenessRuntime.new(
	_publication: PublicationTypes.Runtime,
	_catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	_protocol: ProtocolTypes.ClientProtocol,
	_dependencies: Types.Dependencies,
	_options: Types.Options
): Types.Runtime
	error("N4NotImplemented:ActorAwarenessRuntime.new")
end

return ActorAwarenessRuntime
