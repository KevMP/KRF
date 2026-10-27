--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(script.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Transport = require(script.Parent.Parent.Parent.shared.Networking.Transport)
local Preparation = require(script.Parent.utils.ServerProtocolPreparation)
local Installation = require(script.Parent.utils.NativeServerInstallation)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local ServerNetworking = {} :: Types.ServerNetworking
local installation: Installation.Runtime? = nil
local preparedCatalog: ReplicationTypes.PreparedReplicationDomainCatalog? = nil
local preparedCommands: Types.PreparedCommandCatalog? = nil
local preparedHints: Types.PreparedHintCatalog? = nil

function ServerNetworking.Prepare(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	commands: Types.PreparedCommandCatalog?,
	hints: Types.PreparedHintCatalog?
): (SharedTypes.PreparedProtocol?, string?)
	if ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME) ~= nil then
		return nil, "TransportConflict"
	end

	local protocol, reason = Preparation.Compile(catalog, commands, hints)

	if protocol ~= nil then
		preparedCatalog, preparedCommands, preparedHints = catalog, commands, hints
	end

	return protocol, reason
end

function ServerNetworking.Publish(protocol: SharedTypes.PreparedProtocol): (boolean, string?)
	if installation ~= nil and installation.initialized then
		return false, "NetworkingAlreadyInitialized"
	end

	local transports, reason = Transport.Create(ReplicatedStorage)

	if transports == nil then
		return false, reason
	end

	local created = Installation.new(transports)
	installation = created
	Diagnostics.Start()
	local completed, failure = pcall(created.Start, created, protocol, preparedCatalog, preparedCommands, preparedHints)

	if not completed then
		ServerNetworking.Destroy()
		error(failure, 2)
	end

	return true, nil
end

function ServerNetworking.IsClientReady(player: Player): boolean
	return installation ~= nil and installation:IsClientReady(player)
end

function ServerNetworking.ObserveClientReady(callback: (Player) -> ()): () -> ()
	assert(installation ~= nil, "NetworkingNotInitialized")

	return installation:ObserveClientReady(callback)
end

function ServerNetworking.ObserveClientClosed(callback: (Player) -> ()): () -> ()
	assert(installation ~= nil, "NetworkingNotInitialized")

	return installation:ObserveClientClosed(callback)
end

function ServerNetworking.SendReliable(player: Player, payload: buffer): (boolean, string?)
	if installation == nil then
		return false, "ClientNotReady"
	end

	return installation:SendReliable(player, payload)
end

function ServerNetworking.RequestReplacementBaseline(
	player: Player,
	handle: number,
	reason: string?
): (boolean, string?)
	if installation == nil then
		return false, "ClientNotReady"
	end

	return installation:RequestReplacementBaseline(player, handle, reason)
end

function ServerNetworking.Destroy(): ()
	if installation ~= nil then
		installation:Destroy()
		installation = nil
	end

	preparedCatalog, preparedCommands, preparedHints = nil, nil, nil
	Diagnostics.Stop()
end

function ServerNetworking._IsInitialized(): boolean
	return installation ~= nil and installation.initialized
end

function ServerNetworking._GetPublicationRuntimeForTests(): Types.PublicationRuntime?
	return if installation ~= nil then installation.publication else nil
end

ServerNetworking._ResetForTests = ServerNetworking.Destroy

return ServerNetworking
