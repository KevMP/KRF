--!strict
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local PublicationTypes = require(script.Parent.PublicationTypes)

local types = {}

export type HandshakeDependencies = {
	SendReliable: (player: Player, payload: buffer) -> (),
}
export type ServerHandshake = {
	Handle: (self: ServerHandshake, player: Player, payload: any, ...any) -> (),
	IsClientReady: (self: ServerHandshake, player: Player) -> boolean,
	Send: (self: ServerHandshake, player: Player, payload: buffer) -> (boolean, string?),
	ObserveClientReady: (self: ServerHandshake, callback: (Player) -> ()) -> () -> (),
	ObserveClientClosed: (self: ServerHandshake, callback: (Player) -> ()) -> () -> (),
	Close: (self: ServerHandshake, player: Player) -> (),
	Destroy: (self: ServerHandshake) -> (),
	_GetConnectionCountForTests: (self: ServerHandshake) -> number,
}
export type ServerHandshakeModule = {
	new: (protocol: ProtocolTypes.PreparedProtocol, dependencies: HandshakeDependencies) -> ServerHandshake,
}
export type ServerNetworking = {
	Prepare: (catalog: ReplicationTypes.PreparedReplicationDomainCatalog) -> (ProtocolTypes.PreparedProtocol?, string?),
	Publish: (protocol: ProtocolTypes.PreparedProtocol) -> (boolean, string?),
	IsClientReady: (player: Player) -> boolean,
	ObserveClientReady: (callback: (Player) -> ()) -> () -> (),
	ObserveClientClosed: (callback: (Player) -> ()) -> () -> (),
	SendReliable: (player: Player, payload: buffer) -> (boolean, string?),
	-- Framework-private recovery entrypoint; N4 retains ownership of the installed runtime.
	RequestReplacementBaseline: (player: Player, handle: number, reason: string?) -> (boolean, string?),
	Destroy: () -> (),
	_IsInitialized: () -> boolean,
	_ResetForTests: () -> (),
	-- Framework-private test seam for verifying startup ownership of N3.
	_GetPublicationRuntimeForTests: () -> PublicationTypes.Runtime?,
}

return types
