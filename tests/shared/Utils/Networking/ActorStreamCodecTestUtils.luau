--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.shared.Networking.ActorStreamTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: Types.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Compiler: ProtocolTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local SchemaUtils = require(script.Parent.SchemaTestUtils)

local TestUtils = {}

function TestUtils.protocol(
	domainCode: number?,
	eventCode: number?,
	state: SchemaTypes.SchemaDefinition?
): (ProtocolTypes.ClientProtocol, Types.SchemaCatalog)
	local manifest: ProtocolTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.State",
				code = domainCode or 0,
				state = state or Schema.Struct({
					current = Schema.U8,
					target = Schema.Optional(Schema.String(8)),
					items = Schema.Map(Schema.String(8), Schema.U8, 2),
					order = Schema.Array(Schema.U8, 3),
				}),
				events = { { id = "Changed", code = eventCode or 0, payload = Schema.Struct({ count = Schema.U8 }) } },
			},
			{ id = "Game.Optional", code = 1, state = Schema.Optional(Schema.U8), events = {} },
		},
	}
	-- N2 admits dense codebooks. Foreign catalogs add filler entries so they
	-- remain valid while emitting codes unknown to the smaller receiving catalog.
	for code: number = 0, (domainCode or 0) - 1 do
		if code ~= 1 then
			local filler: ProtocolTypes.ManifestDomain = {
				id = "Game.Filler" .. tostring(code),
				code = code,
				state = Schema.Struct({}),
				events = {},
			}
			table.insert(manifest.domains, filler)
		end
	end
	for code: number = 0, (eventCode or 0) - 1 do
		table.insert(
			manifest.domains[1].events,
			{ id = "Filler" .. tostring(code), code = code, payload = Schema.Struct({}) }
		)
	end
	local protocol: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected compiled stream catalog")
	local schemas: Types.SchemaCatalog = {}
	for _, domain: ProtocolTypes.ManifestDomain in manifest.domains do
		schemas[domain.id] = SchemaUtils.compile(domain.state)
	end
	return protocol, schemas
end

function TestUtils.codec(): Types.Codec
	return Codec.Compile(TestUtils.protocol())
end

function TestUtils.encode(codec: Types.Codec, records: { Types.Record }): buffer
	local payload: buffer?, reason: string? = codec.Encode(records)
	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected encoded Actor packet")
	return payload
end

function TestUtils.decode(codec: Types.Codec, payload: buffer): { Types.Record }
	local records: { Types.Record }?, reason: string? = codec.Decode(payload)
	expect(reason).toBeNil()
	assert(records ~= nil, "Expected decoded Actor packet")
	return records
end

return TestUtils
