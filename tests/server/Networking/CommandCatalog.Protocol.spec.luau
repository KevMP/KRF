--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)

local originalPublish: typeof(Networking.Publish) = Networking.Publish

afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
end)

local function start(
	commands: { NetworkingTypes.CommandDefinition },
	domains: { ReplicationTypes.ReplicationDomainDefinition }?
): SharedTypes.PreparedProtocol
	Server._ResetForTests()
	local captured: SharedTypes.PreparedProtocol? = nil

	Networking.Publish = function(prepared: SharedTypes.PreparedProtocol): (boolean, string?)
		captured = prepared

		return originalPublish(prepared)
	end

	local success: boolean, failure: ServerTypes.StartupFailure? =
		Server.Init({ commands = commands, replicationDomains = domains } :: any)

	expect(success).toBe(true)
	expect(failure).toBeNil()
	assert(captured ~= nil, "Expected actual Server.Init protocol preparation")

	return captured :: SharedTypes.PreparedProtocol
end

it("assigns compact command codes and identical bootstrap bytes regardless of catalog declaration order", function()
	local first: NetworkingTypes.CommandDefinition = Commands.definition("Game.Zeta", "Actor")
	local second: NetworkingTypes.CommandDefinition = Commands.definition("Game.Alpha")

	first.request = Schema.U8
	second.result = Schema.U32

	local domainA: ReplicationTypes.ReplicationDomainDefinition = DomainUtils.createDomain("Game.DomainA")
	local domainB: ReplicationTypes.ReplicationDomainDefinition = DomainUtils.createDomain("Game.DomainB")
	local forward: SharedTypes.PreparedProtocol = start({ first, second }, { domainA, domainB })
	local reverse: SharedTypes.PreparedProtocol = start({ second, first }, { domainB, domainA })
	local metadata: SharedTypes.ProtocolManifest = forward.manifest :: any
	assert(metadata.commands ~= nil, "Expected startup command metadata")
	expect(#metadata.commands).toBe(2)
	expect(reverse.manifest).toEqual(forward.manifest)
	expect(buffer.tostring(reverse.bootstrapBuffer)).toBe(buffer.tostring(forward.bootstrapBuffer))
	local codes: { number } = {}

	for _, command: SharedTypes.ManifestCommand in metadata.commands do
		table.insert(codes, command.code)
	end

	table.sort(codes)
	expect(codes).toEqual({ 0, 1 })
	expect((first :: any).code).toBeNil()
	expect((second :: any).code).toBeNil()
	local reconstructed: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(metadata)
	expect(reason).toBeNil()
	assert(reconstructed ~= nil, "Expected N2 command codec reconstruction")
	local serverProtocol: SharedTypes.ClientProtocol = forward.runtime :: any
	local clientProtocol: SharedTypes.ClientProtocol = reconstructed
	assert(serverProtocol.commandsById ~= nil and clientProtocol.commandsById ~= nil, "Expected command codebooks")

	for id: string, command: SharedTypes.ClientCommand in serverProtocol.commandsById do
		expect(clientProtocol.commandsById[id].code).toBe(command.code)
		expect(clientProtocol.commandsById[id].target).toBe(command.target)
	end

	expect(clientProtocol.domainsById[domainA.id].code).toBe(forward.runtime.domainsById[domainA.id].code)
end)

it("projects only wire metadata and owns immutable schemas after author tables change", function()
	local fields: { [string]: SharedTypes.SchemaDefinition } = { count = Schema.U16 }

	local definition: NetworkingTypes.CommandDefinition = Commands.definition("Game.Projected", "Actor")
	definition.request = { kind = "Struct", fields = fields }
	definition.result = Schema.U32

	local protocol: SharedTypes.PreparedProtocol = start({ definition })
	local metadata: SharedTypes.ProtocolManifest = protocol.manifest :: any
	assert(metadata.commands ~= nil, "Expected command schema metadata")
	local projected: SharedTypes.ManifestCommand = metadata.commands[1]
	local code: number = projected.code

	definition.id = "Game.Mutated"
	definition.target = "None"
	fields.count = Schema.String(16)

	expect(projected).toEqual({
		id = "Game.Projected",
		code = code,
		target = "Actor",
		request = { kind = "Struct", fields = { count = { kind = "U16" } } },
		result = { kind = "U32" },
	})

	expect(table.isfrozen(metadata.commands)).toBe(true)
	expect(table.isfrozen(projected)).toBe(true)
	assert(projected.request ~= nil, "Expected declared request schema")
	expect(table.isfrozen(projected.request)).toBe(true)
	local decoded: SharedTypes.ProtocolMessage = ProtocolUtils.decode(protocol.bootstrapBuffer)
	assert(decoded.kind == "Bootstrap", "Expected N2 Bootstrap")
	expect(decoded.manifest).toEqual(metadata)
end)
