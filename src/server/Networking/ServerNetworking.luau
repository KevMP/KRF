--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local NetworkingTypes = require(script.Parent.types)
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local SharedTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.ProtocolConstants)
local Transport = require(script.Parent.Parent.Parent.shared.Networking.Transport)
local ProtocolCodec = require(script.Parent.Parent.Parent.shared.Networking.ProtocolCodec)
local CodecCompiler = require(script.Parent.Parent.Parent.shared.Networking.CodecCompiler)
local SchemaProjection = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaProjection)
local Handshake = require(script.Parent.ServerHandshake)
local PublicationRuntime = require(script.Parent.PublicationRuntime)
local PublicationLifecycle = require(script.Parent.ActorPublicationLifecycle)
local AwarenessTypes = require(script.Parent.AwarenessTypes)
local Awareness = require(script.Parent.ActorAwarenessRuntime)
local AwarenessLifecycle = require(script.Parent.ActorAwarenessLifecycle)
local Scheduling = require(script.Parent.AwarenessScheduling)
local NativeAssociation = require(script.Parent.NativePlayerAssociation)
local ActorConstants = require(script.Parent.Parent.Parent.shared.Networking.ActorProtocolConstants)

local ServerNetworking = {} :: NetworkingTypes.ServerNetworking
local initialized: boolean = false
local owned: ProtocolTypes.OwnedTransport? = nil
local runtime: NetworkingTypes.ServerHandshake? = nil
local publication: PublicationTypes.Runtime? = nil
local preparedCatalog: ReplicationTypes.PreparedReplicationDomainCatalog? = nil
local listeners: { RBXScriptConnection } = {}
local awareness: AwarenessTypes.Runtime? = nil
local association: AwarenessTypes.AssociationSource? = nil
local stopDriver: (() -> ())? = nil

function ServerNetworking.Prepare(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog
): (ProtocolTypes.PreparedProtocol?, string?)
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
	local domains: { ProtocolTypes.ManifestDomain } = {}
	local eventDefinitions: { [string]: { ReplicationTypes.LoadedReplicationEventDefinition } } = {}
	for index: number, definition: ReplicationTypes.LoadedReplicationDomainDefinition in definitions do
		local events: { ProtocolTypes.ManifestEvent } = {}
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
			local projected: ProtocolTypes.ManifestEvent =
				{ id = event.id, code = eventIndex - 1, payload = SchemaProjection.Definition(event.payload) }
			table.freeze(projected)
			table.insert(events, projected)
		end
		table.freeze(events)
		local domain: ProtocolTypes.ManifestDomain = {
			id = definition.id,
			code = index - 1,
			state = SchemaProjection.Definition(definition.state),
			events = events,
		}
		table.freeze(domain)
		table.insert(domains, domain)
	end
	table.freeze(domains)
	local manifest: ProtocolTypes.ProtocolManifest = { version = Constants.PROTOCOL_VERSION, domains = domains }
	table.freeze(manifest)
	local bootstrapBuffer: buffer?, encodeReason: string? =
		ProtocolCodec.Encode({ kind = "Bootstrap", manifest = manifest })
	if bootstrapBuffer == nil then
		return nil,
			if encodeReason == "BootstrapTooLarge" then "BootstrapManifestTooLarge" else "InvalidProtocolManifest"
	end
	local domainsById: { [string]: ProtocolTypes.ClientDomain } = {}
	local domainsByCode: { [number]: ProtocolTypes.ClientDomain } = {}
	for index: number, definition: ReplicationTypes.LoadedReplicationDomainDefinition in definitions do
		local stateCodec: SharedTypes.CompiledCodec? = CodecCompiler.Compile(definition.state)
		if stateCodec == nil then
			return nil, "CodecCompilationFailure"
		end
		local eventsById: { [string]: ProtocolTypes.ClientEvent } = {}
		local eventsByCode: { [number]: ProtocolTypes.ClientEvent } = {}
		for eventIndex: number, event: ReplicationTypes.LoadedReplicationEventDefinition in
			eventDefinitions[definition.id]
		do
			local codec: SharedTypes.CompiledCodec? = CodecCompiler.Compile(event.payload)
			if codec == nil then
				return nil, "CodecCompilationFailure"
			end
			local installed: ProtocolTypes.ClientEvent = { id = event.id, code = eventIndex - 1, codec = codec }
			table.freeze(installed)
			eventsById[event.id] = installed
			eventsByCode[eventIndex - 1] = installed
		end
		table.freeze(eventsById)
		table.freeze(eventsByCode)
		local installed: ProtocolTypes.ClientDomain = {
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
	local codecs: ProtocolTypes.ClientProtocol = { domainsById = domainsById, domainsByCode = domainsByCode }
	table.freeze(codecs)
	local prepared: ProtocolTypes.PreparedProtocol =
		{ manifest = manifest, bootstrapBuffer = bootstrapBuffer, runtime = codecs }
	table.freeze(prepared)
	preparedCatalog = catalog
	return prepared, nil
end

function ServerNetworking.Publish(protocol: ProtocolTypes.PreparedProtocol): (boolean, string?)
	if initialized then
		return false, "NetworkingAlreadyInitialized"
	end
	local transports: ProtocolTypes.OwnedTransport?, reason: string? = Transport.Create(ReplicatedStorage)
	if transports == nil then
		return false, reason
	end
	owned = transports
	local completed: boolean, failure: any = pcall(function()
		if preparedCatalog ~= nil then
			publication = PublicationRuntime.new(preparedCatalog)
			PublicationLifecycle.Install(publication)
		end
		local handshake: NetworkingTypes.ServerHandshake = Handshake.new(protocol, {
			SendReliable = function(player: Player, payload: buffer): ()
				transports.reliable:FireClient(player, payload)
			end,
		})
		runtime = handshake
		if publication ~= nil and preparedCatalog ~= nil then
			local source: AwarenessTypes.AssociationSource = NativeAssociation.new()
			association = source
			local created: AwarenessTypes.Runtime = Awareness.new(publication, preparedCatalog, protocol.runtime, {
				IsClientReady = ServerNetworking.IsClientReady,
				ObserveClientReady = ServerNetworking.ObserveClientReady,
				ObserveClientClosed = ServerNetworking.ObserveClientClosed,
				SendReliable = ServerNetworking.SendReliable,
				GetPlayerFromCharacter = source.GetPlayerFromCharacter,
				ObserveAssociationChanged = source.ObserveAssociationChanged,
				ReportFault = function(fault: AwarenessTypes.Fault)
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
			local budget: AwarenessTypes.StepBudget = Scheduling.GetBudget()
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
					handshake:Handle(player, payload, ...)
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
	return runtime ~= nil and (runtime :: NetworkingTypes.ServerHandshake):IsClientReady(player)
end

function ServerNetworking.ObserveClientReady(callback: (Player) -> ()): () -> ()
	assert(runtime ~= nil, "NetworkingNotInitialized")
	return (runtime :: NetworkingTypes.ServerHandshake):ObserveClientReady(callback)
end

function ServerNetworking.ObserveClientClosed(callback: (Player) -> ()): () -> ()
	assert(runtime ~= nil, "NetworkingNotInitialized")
	return (runtime :: NetworkingTypes.ServerHandshake):ObserveClientClosed(callback)
end

function ServerNetworking.SendReliable(player: Player, payload: buffer): (boolean, string?)
	if runtime == nil then
		return false, "ClientNotReady"
	end
	return (runtime :: NetworkingTypes.ServerHandshake):Send(player, payload)
end

function ServerNetworking.Destroy(): ()
	initialized = false
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
		(runtime :: NetworkingTypes.ServerHandshake):Destroy()
		runtime = nil
	end
	if owned ~= nil then
		(owned :: ProtocolTypes.OwnedTransport).Destroy()
		owned = nil
	end
end

function ServerNetworking._IsInitialized(): boolean
	return initialized
end

function ServerNetworking._GetPublicationRuntimeForTests(): PublicationTypes.Runtime?
	return publication
end

ServerNetworking._ResetForTests = ServerNetworking.Destroy

return ServerNetworking
