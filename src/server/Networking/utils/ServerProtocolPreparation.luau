--!strict
local Types = require(script.Parent.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ProtocolConstants)
local ProtocolCodec = require(script.Parent.Parent.Parent.Parent.shared.Networking.ProtocolCodec)
local CodecCompiler = require(script.Parent.Parent.Parent.Parent.shared.Networking.CodecCompiler)
local SchemaProjection = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaProjection)
local CommandManifest = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandManifest)
local HintManifest = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.HintManifest)
local Preparation = {}

function Preparation._codebooks(
	definitions: { ReplicationTypes.LoadedReplicationDomainDefinition },
	eventDefinitions: { [string]: { ReplicationTypes.LoadedReplicationEventDefinition } },
	manifest: SharedNetworkingTypes.ProtocolManifest
): (SharedNetworkingTypes.ClientProtocol?, string?)
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
	local commandsById, commandsByCode, commandReason = CommandManifest.Compile(manifest.commands)

	if commandsById == nil or commandsByCode == nil then
		return nil, commandReason or "CodecCompilationFailure"
	end

	local hintsById, hintsByCode, hintReason = HintManifest.Compile(manifest.hints)

	if hintsById == nil or hintsByCode == nil then
		return nil, hintReason or "CodecCompilationFailure"
	end

	local codecs: SharedNetworkingTypes.ClientProtocol = {
		domainsById = domainsById,
		domainsByCode = domainsByCode,
		commandsById = commandsById,
		commandsByCode = commandsByCode,
		hintsById = hintsById,
		hintsByCode = hintsByCode,
	}

	table.freeze(codecs)

	return codecs, nil
end

function Preparation.Compile(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	commands: Types.PreparedCommandCatalog?,
	hints: Types.PreparedHintCatalog?
): (SharedNetworkingTypes.PreparedProtocol?, string?)
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
	local commandMetadata: { SharedNetworkingTypes.ManifestCommand } = {}

	if commands ~= nil then
		for index: number, definition: Types.LoadedCommandDefinition in commands.orderedDefinitions do
			local projected: SharedNetworkingTypes.ManifestCommand = table.freeze({
				id = definition.id,
				code = index - 1,
				target = definition.target,
				request = if definition.request ~= nil then SchemaProjection.Definition(definition.request) else nil,
				result = if definition.result ~= nil then SchemaProjection.Definition(definition.result) else nil,
			})

			table.insert(commandMetadata, projected)
		end
	end

	table.freeze(commandMetadata)
	local hintMetadata: { SharedNetworkingTypes.ManifestHint } = {}

	if hints ~= nil then
		for index: number, definition: Types.LoadedHintDefinition in hints.orderedDefinitions do
			local projected: SharedNetworkingTypes.ManifestHint = table.freeze({
				id = definition.id,
				code = index - 1,
				direction = definition.direction,
				target = definition.target,
				mode = definition.mode,
				payload = SchemaProjection.Definition(definition.payload),
			})

			table.insert(hintMetadata, projected)
		end
	end

	table.freeze(hintMetadata)

	local manifest: SharedNetworkingTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = domains,
		commands = if #commandMetadata > 0 then commandMetadata else nil,
		hints = if #hintMetadata > 0 then hintMetadata else nil,
	}

	table.freeze(manifest)

	local bootstrapBuffer: buffer?, encodeReason: string? =
		ProtocolCodec.Encode({ kind = "Bootstrap", manifest = manifest })

	if bootstrapBuffer == nil then
		return nil,
			if encodeReason == "BootstrapTooLarge" then "BootstrapManifestTooLarge" else "InvalidProtocolManifest"
	end

	local codecs, reason = Preparation._codebooks(definitions, eventDefinitions, manifest)

	if codecs == nil then
		return nil, reason
	end

	local prepared: SharedNetworkingTypes.PreparedProtocol =
		{ manifest = manifest, bootstrapBuffer = bootstrapBuffer, runtime = codecs }

	table.freeze(prepared)

	return prepared, nil
end

return Preparation
