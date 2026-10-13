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
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Compiler: NetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalCompile: typeof(Compiler.Compile) = Compiler.Compile

beforeEach(function()
	Domains._resetForTests()
	Networking._ResetForTests()
end)

afterEach(function()
	Compiler.Compile = originalCompile
	Domains._resetForTests()
	Networking._ResetForTests()
end)

it("assigns unique compact domain codes independently of consumer declaration order", function()
	local firstDomain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Zeta")
	local secondDomain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Alpha")
	local first: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ firstDomain, secondDomain })
	local second: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ secondDomain, firstDomain })
	expect(second.manifest).toEqual(first.manifest)
	expect(buffer.tostring(second.bootstrapBuffer)).toBe(buffer.tostring(first.bootstrapBuffer))
	local codes: { number } = {}
	for _, domain: ProtocolTypes.ManifestDomain in first.manifest.domains do
		table.insert(codes, domain.code)
	end
	table.sort(codes)
	expect(codes).toEqual({ 0, 1 })
	-- Numeric values remain private and are absent from consumer domain definitions.
	expect((firstDomain :: any).code).toBeNil()
	expect((Domains :: any).GetDomainCode).toBeNil()
end)

it("assigns event codes within each domain independently of event declaration order", function()
	local firstDomain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Actions")
	firstDomain.events = { { id = "Started", payload = Schema.U8 }, { id = "Ended", payload = Schema.Boolean } }
	local secondDomain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Inventory")
	secondDomain.events = { { id = "Started", payload = Schema.U16 } }
	local first: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ firstDomain, secondDomain })
	firstDomain.events = { { id = "Ended", payload = Schema.Boolean }, { id = "Started", payload = Schema.U8 } }
	local second: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ secondDomain, firstDomain })
	expect(second.manifest).toEqual(first.manifest)
	local actionDomain: ProtocolTypes.ClientDomain = first.runtime.domainsById["Game.Actions"]
	expect(actionDomain.eventsById.Started.code == actionDomain.eventsById.Ended.code).toBe(false)
	expect(first.runtime.domainsById["Game.Inventory"].eventsById.Started.id).toBe("Started")
end)

it("includes state, event and Enum descriptions while omitting all server implementation details", function()
	local callbackCalls: number = 0
	local domain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.State")
	domain.state = Schema.Struct({ mode = Schema.Enum({ "Idle", "Blocking" }) })
	domain.events = { { id = "Changed", payload = Schema.Struct({ value = Schema.U8 }) } }
	domain.audience = "Owner"
	domain.snapshot = function(): any
		callbackCalls += 1
		error("Snapshot must not run during bootstrap")
	end
	domain.observe = function(): (() -> ())?
		callbackCalls += 1
		error("Observe must not run during bootstrap")
	end
	local protocol: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ domain })
	expect(callbackCalls).toBe(0)
	expect(protocol.manifest).toEqual({
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.State",
				code = protocol.runtime.domainsById["Game.State"].code,
				state = { kind = "Struct", fields = { mode = { kind = "Enum", values = { "Blocking", "Idle" } } } },
				events = {
					{
						id = "Changed",
						code = protocol.runtime.domainsById["Game.State"].eventsById.Changed.code,
						payload = { kind = "Struct", fields = { value = { kind = "U8" } } },
					},
				},
			},
		},
	})
	local decoded: ProtocolTypes.Message = ProtocolTestUtils.decode(protocol.bootstrapBuffer)
	assert(decoded.kind == "Bootstrap", "Expected Bootstrap")
	expect(decoded.manifest).toEqual(protocol.manifest)
	expect(table.isfrozen(protocol.manifest)).toBe(true)
	expect(table.isfrozen(protocol.manifest.domains)).toBe(true)
	expect(table.isfrozen(protocol.manifest.domains[1])).toBe(true)
end)

it("owns immutable protocol metadata without publishing the server registry during preparation", function()
	local domain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Original")
	local protocol: ProtocolTypes.PreparedProtocol = TestUtils.prepare({ domain })
	domain.id = "Game.Mutated"
	domain.state = Schema.F64
	expect(protocol.manifest.domains[1].id).toBe("Game.Original")
	expect(protocol.runtime.domainsById["Game.Original"].stateCodec.fixedSizeBytes).toBe(1)
	expect(Domains.IsLoaded()).toBe(false)
	expect(Networking._IsInitialized()).toBe(false)
end)

it("prepares an empty catalog without adding Actor or built-in gameplay identities", function()
	local protocol: ProtocolTypes.PreparedProtocol = TestUtils.prepare({})
	expect(protocol.manifest.domains).toEqual({})
	expect(protocol.runtime.domainsById).toEqual({})
	expect((protocol.manifest :: any).actors).toBeNil()
	expect((protocol.manifest :: any).actorHandles).toBeNil()
end)

it("fails preparation when the encoded manifest exceeds the private bootstrap budget", function()
	local domain: ReplicationTypes.ReplicationDomainDefinition =
		DomainTestUtils.createDomain(string.rep("x", Constants.MAX_BOOTSTRAP_BYTES + 1))
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare({ domain })
	local protocol: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(protocol).toBeNil()
	expect(reason).toBe("BootstrapManifestTooLarge")
	expect(Networking._IsInitialized()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
end)

it("surfaces codec compilation failure without retaining a partially usable protocol", function()
	local calls: number = 0
	Compiler.Compile = function(schema: NetworkingTypes.CompiledSchema): (NetworkingTypes.CompiledCodec?, string?)
		calls += 1
		if calls == 2 then
			return nil, "UnsupportedCodecFeature"
		end
		return originalCompile(schema)
	end
	local first: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.First")
	local second: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Second")
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare({ first, second })
	local protocol: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(protocol).toBeNil()
	expect(reason).toBe("CodecCompilationFailure")
	expect(calls).toBe(2)
	expect(Networking._IsInitialized()).toBe(false)
end)
