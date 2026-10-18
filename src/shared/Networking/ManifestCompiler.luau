--!strict
local Types = require(script.Parent.types)
local Constants = require(script.Parent.utils.ProtocolConstants)
local SchemaCompiler = require(script.Parent.utils.SchemaCompiler)
local CodecCompiler = require(script.Parent.CodecCompiler)
local CollectionUtils = require(script.Parent.utils.SchemaCollectionUtils)
local BufferUtils = require(script.Parent.utils.CodecBufferUtils)

local ManifestCompiler = {} :: Types.ManifestCompiler

local function onlyFields(value: any, allowed: { [string]: boolean }): boolean
	if type(value) ~= "table" then
		return false
	end

	for field in next, value do
		if type(field) ~= "string" or not allowed[field] then
			return false
		end
	end

	return true
end

local function codecFor(definition: Types.SchemaDefinition): (Types.CompiledCodec?, string?)
	local schema: Types.CompiledSchema?, reason: string? = SchemaCompiler.Compile(definition)

	if schema == nil then
		return nil, if reason == "SchemaKindInvalid" then "UnsupportedSchema" else "MalformedBootstrap"
	end

	local codec: Types.CompiledCodec?, codecReason: string? = CodecCompiler.Compile(schema)

	if codec == nil then
		return nil, codecReason or "UnsupportedSchema"
	end

	return codec, nil
end

function ManifestCompiler.Reconstruct(manifest: Types.ProtocolManifest): (Types.ClientProtocol?, string?)
	if not onlyFields(manifest, { version = true, domains = true }) then
		return nil, "MalformedBootstrap"
	end

	if type(manifest.version) ~= "number" or not BufferUtils.IsOffset(manifest.version, 65535) then
		return nil, "MalformedBootstrap"
	end

	if manifest.version ~= Constants.PROTOCOL_VERSION then
		return nil, "ProtocolMismatch"
	end

	local domainCount: number? = CollectionUtils.GetArrayLength(manifest.domains)

	if domainCount == nil then
		return nil, "MalformedBootstrap"
	end

	local domainsById: { [string]: Types.ClientDomain } = {}
	local domainsByCode: { [number]: Types.ClientDomain } = {}

	for _, domain: Types.ManifestDomain in manifest.domains do
		if not onlyFields(domain, { id = true, code = true, state = true, events = true }) then
			return nil, "MalformedBootstrap"
		end

		if
			type(domain.id) ~= "string"
			or domain.id == ""
			or type(domain.code) ~= "number"
			or not BufferUtils.IsOffset(domain.code, domainCount - 1)
			or domainsById[domain.id] ~= nil
			or domainsByCode[domain.code] ~= nil
		then
			return nil, "MalformedBootstrap"
		end

		local eventCount: number? = CollectionUtils.GetArrayLength(domain.events)

		if eventCount == nil then
			return nil, "MalformedBootstrap"
		end

		local stateCodec: Types.CompiledCodec?, stateReason: string? = codecFor(domain.state)

		if stateCodec == nil then
			return nil, stateReason
		end

		local eventsById: { [string]: Types.ClientEvent } = {}
		local eventsByCode: { [number]: Types.ClientEvent } = {}

		for _, event: Types.ManifestEvent in domain.events do
			if not onlyFields(event, { id = true, code = true, payload = true }) then
				return nil, "MalformedBootstrap"
			end

			if
				type(event.id) ~= "string"
				or event.id == ""
				or type(event.code) ~= "number"
				or not BufferUtils.IsOffset(event.code, eventCount - 1)
				or eventsById[event.id] ~= nil
				or eventsByCode[event.code] ~= nil
			then
				return nil, "MalformedBootstrap"
			end

			local codec: Types.CompiledCodec?, reason: string? = codecFor(event.payload)

			if codec == nil then
				return nil, reason
			end

			local installed: Types.ClientEvent = { id = event.id, code = event.code, codec = codec }
			table.freeze(installed)
			eventsById[event.id] = installed :: Types.ClientEvent?
			eventsByCode[event.code] = installed :: Types.ClientEvent?
		end

		table.freeze(eventsById)
		table.freeze(eventsByCode)

		local installed: Types.ClientDomain = {
			id = domain.id,
			code = domain.code,
			stateCodec = stateCodec,
			eventsById = eventsById,
			eventsByCode = eventsByCode,
		}

		table.freeze(installed)
		domainsById[domain.id] = installed :: Types.ClientDomain?
		domainsByCode[domain.code] = installed :: Types.ClientDomain?
	end

	table.freeze(domainsById)
	table.freeze(domainsByCode)
	local runtime: Types.ClientProtocol = { domainsById = domainsById, domainsByCode = domainsByCode }
	table.freeze(runtime)

	return runtime :: Types.ClientProtocol?, nil
end

return ManifestCompiler
