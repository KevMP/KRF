--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local NetworkingTypes = require(KRF.shared.Networking.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local ManifestCompiler: ProtocolTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local ServerTestUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local SchemaTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local CodecTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.CodecTestUtils)

local MAX_SAFE_INTEGER: number = 9007199254740991
type BoundsCase = { name: string, definition: NetworkingTypes.SchemaDefinition, value: any }
local cases: { BoundsCase } = {}
-- N1 reserves up to eight bytes for collection prefixes. The near-limit cases
-- leave that allowance intact, so these are compiled-legal descriptors.
for _, maximum: number in { 4294967296, 2 ^ 40 + 1, 2 ^ 52 + 1, MAX_SAFE_INTEGER - 8 } do
	table.insert(
		cases,
		{ name = "String bound " .. tostring(maximum), definition = Schema.String(maximum), value = "x" }
	)
	table.insert(
		cases,
		{ name = "Array bound " .. tostring(maximum), definition = Schema.Array(Schema.U8, maximum), value = { 0 } }
	)
	table.insert(cases, {
		name = "Map bound " .. tostring(maximum),
		definition = Schema.Map(Schema.U8, Schema.Struct({}), maximum),
		value = { [0] = {} },
	})
end
table.insert(cases, {
	name = "Array cardinality at MAX_SAFE_INTEGER",
	definition = Schema.Array(Schema.Struct({}), MAX_SAFE_INTEGER),
	value = { {}, {} },
})
table.insert(cases, {
	name = "large bounds nested under Struct and Optional",
	definition = Schema.Struct({
		note = Schema.Optional(Schema.String(2 ^ 40 + 1)),
		records = Schema.Array(Schema.Map(Schema.U8, Schema.Boolean, 2 ^ 40 + 1), 1),
	}),
	value = { records = { { [0] = false } } },
})

beforeEach(function()
	Domains._resetForTests()
	Networking._ResetForTests()
end)
afterEach(function()
	Domains._resetForTests()
	Networking._ResetForTests()
end)

for _, testCase: BoundsCase in cases do
	it("preserves legal " .. testCase.name .. " exactly through server manifest and bootstrap serialization", function()
		local originalSchema: NetworkingTypes.CompiledSchema = SchemaTestUtils.compile(testCase.definition)
		local domain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.LargeBounds")
		domain.state = testCase.definition
		domain.events = { { id = "Changed", payload = testCase.definition } }
		local protocol: ProtocolTypes.PreparedProtocol = ServerTestUtils.prepare({ domain })
		local manifestDomain: ProtocolTypes.ManifestDomain = protocol.manifest.domains[1]
		expect(manifestDomain.state).toEqual(testCase.definition)
		expect(manifestDomain.events[1].payload).toEqual(testCase.definition)
		-- A large potential gameplay value must not cause a giant metadata packet.
		expect(buffer.len(protocol.bootstrapBuffer) <= Constants.MAX_BOOTSTRAP_BYTES).toBe(true)
		local decoded: ProtocolTypes.Message = ProtocolTestUtils.decode(protocol.bootstrapBuffer)
		assert(decoded.kind == "Bootstrap", "Expected Bootstrap")
		local decodedDomain: ProtocolTypes.ManifestDomain = decoded.manifest.domains[1]
		expect(decodedDomain.state).toEqual(testCase.definition)
		expect(decodedDomain.events[1].payload).toEqual(testCase.definition)
		expect(SchemaTestUtils.compile(decodedDomain.state)).toEqual(originalSchema)
		expect(SchemaTestUtils.compile(decodedDomain.events[1].payload)).toEqual(originalSchema)
		local clientProtocol: ProtocolTypes.ClientProtocol?, reason: string? =
			ManifestCompiler.Reconstruct(decoded.manifest)
		expect(reason).toBeNil()
		assert(clientProtocol ~= nil, "Expected compatible client protocol for legal N1 bounds")
		local clientDomain: ProtocolTypes.ClientDomain = clientProtocol.domainsById[domain.id]
		local codecs: { NetworkingTypes.CompiledCodec } = {
			protocol.runtime.domainsById[domain.id].stateCodec,
			protocol.runtime.domainsById[domain.id].eventsById.Changed.codec,
			clientDomain.stateCodec,
			clientDomain.eventsById.Changed.codec,
		}
		for _, codec: NetworkingTypes.CompiledCodec in codecs do
			expect(codec.maxSizeBytes <= originalSchema.maxEncodedBytes).toBe(true)
			CodecTestUtils.expectRoundTrip(codec, testCase.value)
		end
	end)
end
