--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Types = require(script.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.ProtocolConstants)
local Transport = require(script.Parent.Parent.Parent.shared.Networking.Transport)
local ProtocolCodec = require(script.Parent.Parent.Parent.shared.Networking.ProtocolCodec)
local CodecCompiler = require(script.Parent.Parent.Parent.shared.Networking.CodecCompiler)
local SchemaProjection = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaProjection)
local Handshake = require(script.Parent.ServerHandshake)
local PublicationRuntime = require(script.Parent.PublicationRuntime)
local PublicationLifecycle = require(script.Parent.utils.ActorPublicationLifecycle)
local Awareness = require(script.Parent.ActorAwarenessRuntime)
local AwarenessLifecycle = require(script.Parent.utils.ActorAwarenessLifecycle)
local Scheduling = require(script.Parent.utils.AwarenessScheduling)
local NativeAssociation = require(script.Parent.utils.NativePlayerAssociation)
local ActorConstants = require(script.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)
local Resync = require(script.Parent.ResyncRuntime)

local ServerNetworking = {} :: Types.ServerNetworking
local initialized: boolean = false
local owned: SharedNetworkingTypes.OwnedTransport? = nil
local runtime: Types.ServerHandshake? = nil
local publication: Types.PublicationRuntime? = nil
local preparedCatalog: ReplicationTypes.PreparedReplicationDomainCatalog? = nil
local listeners: { RBXScriptConnection } = {}
local awareness: Types.ActorAwarenessRuntime? = nil
local association: Types.PlayerAssociationSource? = nil
local stopDriver: (() -> ())? = nil
local resync: Types.ResyncRuntime? = nil

function ServerNetworking.Prepare(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog
): (SharedNetworkingTypes.PreparedProtocol?, string?)
	if ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME) ~= nil then
		return nil, "TransportConflict"
	end
	local definitions: { ReplicationTypes.LoadedReplicationDomainDefinition } = table.clone(catalog.orderedDefinitions)
	table.sort(
		definitions,
		function(
			first: ReplicationTypes.LoadedReplicationDomainDefinition,
			second: ReplicationTypes.LoadedReplicationDomainDefinition
		): boolean
			return first.id < second.id
		end
	)
	local domains: { SharedNetworkingTypes.ManifestDomain } = {}
	local eventDefinitions: { [string]: { ReplicationTypes.LoadedReplicationEventDefinition } } = {}
	for index: number, definition: ReplicationTypes.LoadedReplicationDomainDefinition in definitions do
		local events: { SharedNetworkingTypes.ManifestEvent } = {}
		local orderedEvents: { ReplicationTypes.LoadedReplicationEventDefinition } = table.clone(definition.events)
		table.sort(
			orderedEvents,
			function(
				first: ReplicationTypes.LoadedReplicationEventDefinition,
				second: ReplicationTypes.LoadedReplicationEventDefinition
			): boolean
				return first.id < second.id
			end
		)
		eventDefinitions[definition.id] = orderedEvents
		for eventIndex: number, event: ReplicationTypes.LoadedReplicationEventDefinition in orderedEvents do
			local projected: SharedNetworkingTypes.ManifestEvent =
				{ id = event.id, code = eventIndex - 1, payload = SchemaProjection.Definition(event.payload) }
			table.freeze(projected)
			table.insert(events, projected)
		end
		table.freeze(events)
		local domain: SharedNetworkingTypes.ManifestDomain = {
			id = definition.id,
			code = index - 1,
			state = SchemaProjection.Definition(definition.state),
			events = events,
		}
		table.freeze(domain)
		table.insert(domains, domain)
	end
	table.freeze(domains)
	local manifest: SharedNetworkingTypes.ProtocolManifest = { version = Constants.PROTOCOL_VERSION, domains = domains }
	table.freeze(manifest)
	local bootstrapBuffer: buffer?, encodeReason: string? =
		ProtocolCodec.Encode({ kind = "Bootstrap", manifest = manifest })
	if bootstrapBuffer == nil then
		return nil,
			if encodeReason == "BootstrapTooLarge" then "BootstrapManifestTooLarge" else "InvalidProtocolManifest"
	end
	local domainsById: { [string]: SharedNetworkingTypes.ClientDomain } = {}
	local domainsByCode: { [number]: SharedNetworkingTypes.ClientDomain } = {}
	for index: number, definition: ReplicationTypes.LoadedReplicationDomainDefinition in definitions do
		local stateCodec: SharedNetworkingTypes.CompiledCodec? = CodecCompiler.Compile(definition.state)
		if stateCodec == nil then
			return nil, "CodecCompilationFailure"
		end
		local eventsById: { [string]: SharedNetworkingTypes.ClientEvent } = {}
		local eventsByCode: { [number]: SharedNetworkingTypes.ClientEvent } = {}
		for eventIndex: number, event: ReplicationTypes.LoadedReplicationEventDefinition in
			eventDefinitions[definition.id]
		do
			local codec: SharedNetworkingTypes.CompiledCodec? = CodecCompiler.Compile(event.payload)
			if codec == nil then
				return nil, "CodecCompilationFailure"
			end
			local installed: SharedNetworkingTypes.ClientEvent = { id = event.id, code = eventIndex - 1, codec = codec }
			table.freeze(installed)
			eventsById[event.id] = installed
			eventsByCode[eventIndex - 1] = installed
		end
		table.freeze(eventsById)
		table.freeze(eventsByCode)
		local installed: SharedNetworkingTypes.ClientDomain = {
			id = definition.id,
			code = index - 1,
			stateCodec = stateCodec,
			eventsById = eventsById,
			eventsByCode = eventsByCode,
		}
		table.freeze(installed)
		domainsById[definition.id] = installed
		domainsByCode[index - 1] = installed
	end
	table.freeze(domainsById)
	table.freeze(domainsByCode)
	local codecs: SharedNetworkingTypes.ClientProtocol = { domainsById = domainsById, domainsByCode = domainsByCode }
	table.freeze(codecs)
	local prepared: SharedNetworkingTypes.PreparedProtocol =
		{ manifest = manifest, bootstrapBuffer = bootstrapBuffer, runtime = codecs }
	table.freeze(prepared)
	preparedCatalog = catalog
	return prepared, nil
end

function ServerNetworking.Publish(protocol: SharedNetworkingTypes.PreparedProtocol): (boolean, string?)
	if initialized then
		return false, "NetworkingAlreadyInitialized"
	end
	local transports: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Create(ReplicatedStorage)
	if transports == nil then
		return false, reason
	end
	owned = transports
	local completed: boolean, failure: any = pcall(function()
		if preparedCatalog ~= nil then
			publication = PublicationRuntime.new(preparedCatalog)
			PublicationLifecycle.Install(publication)
		end
		local handshake: Types.ServerHandshake = Handshake.new(protocol, {
			SendReliable = function(player: Player, payload: buffer): ()
				transports.reliable:FireClient(player, payload)
			end,
		})
		runtime = handshake
		if publication ~= nil and preparedCatalog ~= nil then
			local source: Types.PlayerAssociationSource = NativeAssociation.new()
			association = source
			local created: Types.ActorAwarenessRuntime = Awareness.new(publication, preparedCatalog, protocol.runtime, {
				IsClientReady = ServerNetworking.IsClientReady,
				ObserveClientReady = ServerNetworking.ObserveClientReady,
				ObserveClientClosed = ServerNetworking.ObserveClientClosed,
				SendReliable = ServerNetworking.SendReliable,
				GetPlayerFromCharacter = source.GetPlayerFromCharacter,
				ObserveAssociationChanged = source.ObserveAssociationChanged,
				ReportFault = function(fault: Types.ActorAwarenessFault)
					warn(
						"[Networking] Actor stream halted actorId="
							.. fault.actorId
							.. " recipient="
							.. tostring(fault.player)
							.. " reason="
							.. fault.reason
					)
				end,
			}, {
				maxBaselineBytes = ActorConstants.MAX_BASELINE_BYTES,
				maxChunkBytes = ActorConstants.CHUNK_BYTES,
				maxQueuedBytes = ActorConstants.MAX_QUEUED_BYTES,
				maxEvents = ActorConstants.MAX_EVENTS,
				maxHandle = ActorConstants.MAX_COUNTER,
				maxRevision = ActorConstants.MAX_COUNTER,
			})
			awareness = created
			AwarenessLifecycle.Install(created)
			resync = Resync.new({
				Now = os.clock,
				IsClientReady = ServerNetworking.IsClientReady,
				ObserveClientClosed = ServerNetworking.ObserveClientClosed,
				RequestReplacementBaseline = ServerNetworking.RequestReplacementBaseline,
			}, {
				windowSeconds = ActorConstants.RESYNC_WINDOW_SECONDS,
				maxRequestsPerClient = ActorConstants.MAX_RESYNC_PER_CLIENT,
				maxRequestsPerActor = ActorConstants.MAX_RESYNC_PER_ACTOR,
			})
			local budget: Types.AwarenessStepBudget = Scheduling.GetBudget()
			stopDriver = Scheduling.ObserveStep(function()
				if initialized and awareness == created then
					created:Step(budget.maxBytes, budget.maxRecords)
				end
			end)
		end
		table.insert(
			listeners,
			transports.reliable.OnServerEvent:Connect(function(player: Player, payload: any, ...: any): ()
				if initialized and player.Parent == Players then
					if
						resync ~= nil
						and typeof(payload) == "buffer"
						and buffer.len(payload) > 0
						and buffer.readu8(payload, 0) == ActorConstants.RESYNC_PACKET_KIND
					then
						resync:Handle(player, payload, ...)
					else
						handshake:Handle(player, payload, ...)
					end
				end
			end)
		)
		table.insert(
			listeners,
			Players.PlayerRemoving:Connect(function(player: Player): ()
				handshake:Close(player)
			end)
		)
		-- The unreliable lane is reserved. No message kinds or consumers exist on it.
		initialized = true
	end)
	if not completed then
		ServerNetworking.Destroy()
		error(failure, 2)
	end
	return true, nil
end

function ServerNetworking.IsClientReady(player: Player): boolean
	return runtime ~= nil and (runtime :: Types.ServerHandshake):IsClientReady(player)
end

function ServerNetworking.ObserveClientReady(callback: (Player) -> ()): () -> ()
	assert(runtime ~= nil, "NetworkingNotInitialized")
	return (runtime :: Types.ServerHandshake):ObserveClientReady(callback)
end

function ServerNetworking.ObserveClientClosed(callback: (Player) -> ()): () -> ()
	assert(runtime ~= nil, "NetworkingNotInitialized")
	return (runtime :: Types.ServerHandshake):ObserveClientClosed(callback)
end

function ServerNetworking.SendReliable(player: Player, payload: buffer): (boolean, string?)
	if runtime == nil then
		return false, "ClientNotReady"
	end
	return (runtime :: Types.ServerHandshake):Send(player, payload)
end

function ServerNetworking.RequestReplacementBaseline(
	player: Player,
	handle: number,
	reason: string?
): (boolean, string?)
	if not initialized or awareness == nil then
		return false, "ClientNotReady"
	end
	return (awareness :: Types.ActorAwarenessRuntime):RequestReplacementBaseline(player, handle, reason)
end

function ServerNetworking.Destroy(): ()
	initialized = false
	if resync ~= nil then
		resync:Destroy()
		resync = nil
	end
	AwarenessLifecycle.Install(nil)
	if stopDriver ~= nil then
		stopDriver()
		stopDriver = nil
	end
	if awareness ~= nil then
		awareness:Destroy()
		awareness = nil
	end
	if association ~= nil then
		association.Destroy()
		association = nil
	end
	PublicationLifecycle.Install(nil)
	if publication ~= nil then
		publication:Destroy()
		publication = nil
	end
	preparedCatalog = nil
	for _, listener: RBXScriptConnection in listeners do
		listener:Disconnect()
	end
	table.clear(listeners)
	if runtime ~= nil then
		(runtime :: Types.ServerHandshake):Destroy()
		runtime = nil
	end
	if owned ~= nil then
		(owned :: SharedNetworkingTypes.OwnedTransport).Destroy()
		owned = nil
	end
end

function ServerNetworking._IsInitialized(): boolean
	return initialized
end

function ServerNetworking._GetPublicationRuntimeForTests(): Types.PublicationRuntime?
	return publication
end

ServerNetworking._ResetForTests = ServerNetworking.Destroy

return ServerNetworking
