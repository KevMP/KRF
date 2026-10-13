--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Compiler: ProtocolTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ProtocolTestUtils)
local CodecTestUtils = require(script.Parent.Parent.Utils.Networking.CodecTestUtils)

it("bootstraps compatible client codecs for every N1 schema kind", function()
	local definition: NetworkingTypes.SchemaDefinition = Schema.Struct({
		boolean = Schema.Boolean,
		u8 = Schema.U8,
		u16 = Schema.U16,
		u32 = Schema.U32,
		i8 = Schema.I8,
		i16 = Schema.I16,
		i32 = Schema.I32,
		f32 = Schema.F32,
		f64 = Schema.F64,
		string = Schema.String(8),
		enum = Schema.Enum({ "Active", "Idle" }),
		optional = Schema.Optional(Schema.U8),
		array = Schema.Array(Schema.Boolean, 2),
		map = Schema.Map(Schema.String(4), Schema.Struct({ count = Schema.U16 }), 2),
	})
	local manifest: ProtocolTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.AllKinds",
				code = 0,
				state = definition,
				events = { { id = "Changed", code = 0, payload = definition } },
			},
		},
	}
	local decoded: ProtocolTypes.Message =
		TestUtils.decode(TestUtils.encode({ kind = "Bootstrap", manifest = manifest }))
	assert(decoded.kind == "Bootstrap", "Expected Bootstrap")
	local runtime: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(decoded.manifest)
	expect(reason).toBeNil()
	assert(runtime ~= nil, "Expected client protocol")
	local value: any = {
		boolean = false,
		u8 = 255,
		u16 = 65535,
		u32 = 4294967295,
		i8 = -128,
		i16 = -32768,
		i32 = -2147483648,
		f32 = 1.25,
		f64 = math.pi,
		string = "é\0",
		enum = "Idle",
		array = { false, true },
		map = { zero = { count = 0 } },
	}
	local encoded: buffer = CodecTestUtils.encode(CodecTestUtils.compile(definition), value)
	for _, codec: NetworkingTypes.CompiledCodec in
		{
			runtime.domainsById["Game.AllKinds"].stateCodec,
			runtime.domainsById["Game.AllKinds"].eventsById.Changed.codec,
		}
	do
		local reconstructed: any, offset: number?, readReason: string? = codec.Read(encoded, 0, buffer.len(encoded))
		expect(reconstructed).toEqual(value)
		expect(offset).toBe(buffer.len(encoded))
		expect(readReason).toBeNil()
	end
end)

it("reconstructs matching bidirectional domain and event mappings with compatible codecs", function()
	local manifest: ProtocolTypes.ProtocolManifest = TestUtils.manifest()
	local runtime: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
	expect(reason).toBeNil()
	assert(runtime ~= nil, "Expected a client protocol")
	for _, domain: ProtocolTypes.ManifestDomain in manifest.domains do
		local installed: ProtocolTypes.ClientDomain = runtime.domainsById[domain.id]
		expect(runtime.domainsByCode[domain.code]).toBe(installed)
		expect(installed.code).toBe(domain.code)
		for _, event: ProtocolTypes.ManifestEvent in domain.events do
			local installedEvent: ProtocolTypes.ClientEvent = installed.eventsById[event.id]
			expect(installed.eventsByCode[event.code]).toBe(installedEvent)
			CodecTestUtils.expectRoundTrip(installedEvent.codec, { count = 65535 })
		end
	end
	CodecTestUtils.expectRoundTrip(runtime.domainsById["Game.Actions"].stateCodec, { mode = "Idle", active = false })
	CodecTestUtils.expectRoundTrip(runtime.domainsById["Game.Inventory"].stateCodec, { "first", "second" })
end)

it("reconstructs usable codecs after a buffer-backed manifest round trip", function()
	local payload: buffer = TestUtils.encode({ kind = "Bootstrap", manifest = TestUtils.manifest() })
	local decoded: ProtocolTypes.Message = TestUtils.decode(payload)
	assert(decoded.kind == "Bootstrap", "Expected Bootstrap")
	local runtime: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(decoded.manifest)
	expect(reason).toBeNil()
	assert(runtime ~= nil, "Expected client codec metadata")
	CodecTestUtils.expectRoundTrip(runtime.domainsById["Game.Actions"].stateCodec, { mode = "Blocking", active = true })
end)

type InvalidManifestCase = { name: string, mutate: (any) -> (), reason: string }
local invalidCases: { InvalidManifestCase } = {
	{
		name = "protocol mismatch",
		mutate = function(manifest: any)
			manifest.version = Constants.PROTOCOL_VERSION + 1
		end,
		reason = "ProtocolMismatch",
	},
	{
		name = "unknown schema kind",
		mutate = function(manifest: any)
			manifest.domains[2].state = { kind = "FutureSchema" }
		end,
		reason = "UnsupportedSchema",
	},
	{
		name = "unsupported nested feature",
		mutate = function(manifest: any)
			manifest.domains[1].events[1].payload = { kind = "Optional", inner = { kind = "FutureSchema" } }
		end,
		reason = "UnsupportedSchema",
	},
	{
		name = "missing schema bound",
		mutate = function(manifest: any)
			manifest.domains[2].state = { kind = "String" }
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "duplicate domain id",
		mutate = function(manifest: any)
			manifest.domains[2].id = manifest.domains[1].id
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "duplicate domain code",
		mutate = function(manifest: any)
			manifest.domains[2].code = manifest.domains[1].code
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "negative domain code",
		mutate = function(manifest: any)
			manifest.domains[1].code = -1
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "fractional event code",
		mutate = function(manifest: any)
			manifest.domains[1].events[1].code = 0.5
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "duplicate event id",
		mutate = function(manifest: any)
			table.insert(manifest.domains[1].events, { id = "Changed", code = 1, payload = { kind = "U8" } })
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "duplicate event code",
		mutate = function(manifest: any)
			table.insert(manifest.domains[1].events, { id = "Other", code = 0, payload = { kind = "U8" } })
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "duplicate Enum member",
		mutate = function(manifest: any)
			manifest.domains[2].state = { kind = "Enum", values = { "Idle", "Idle" } }
		end,
		reason = "MalformedBootstrap",
	},
	{
		name = "server callback field",
		mutate = function(manifest: any)
			manifest.domains[1].snapshot = function() end
		end,
		reason = "MalformedBootstrap",
	},
}
for _, testCase: InvalidManifestCase in invalidCases do
	it("rejects " .. testCase.name .. " without publishing partial decoder metadata", function()
		local manifest: ProtocolTypes.ProtocolManifest = TestUtils.manifest()
		testCase.mutate(manifest)
		local runtime: ProtocolTypes.ClientProtocol? = nil
		local reason: string? = nil
		local completed: boolean = pcall(function()
			runtime, reason = Compiler.Reconstruct(manifest)
		end)
		expect(completed).toBe(true)
		expect(runtime).toBeNil()
		expect(reason).toBe(testCase.reason)
	end)
end

it("allows empty global catalogs and the same event id in different domains", function()
	local empty: ProtocolTypes.ClientProtocol?, emptyReason: string? =
		Compiler.Reconstruct({ version = Constants.PROTOCOL_VERSION, domains = {} })
	expect(emptyReason).toBeNil()
	assert(empty ~= nil, "Expected empty protocol")
	expect(empty.domainsById).toEqual({})
	expect(empty.domainsByCode).toEqual({})
	local manifest: ProtocolTypes.ProtocolManifest = TestUtils.manifest()
	local secondDomain: ProtocolTypes.ManifestDomain = manifest.domains[2]
	manifest.domains[2] = {
		id = secondDomain.id,
		code = secondDomain.code,
		state = secondDomain.state,
		events = { { id = "Changed", code = 0, payload = manifest.domains[1].events[1].payload } },
	}
	local runtime: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
	expect(reason).toBeNil()
	assert(runtime ~= nil, "Expected protocol")
	expect(runtime.domainsById["Game.Actions"].eventsById.Changed).never.toBe(
		runtime.domainsById["Game.Inventory"].eventsById.Changed
	)
end)
