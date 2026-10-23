--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local ProtocolUtils = require(script.Parent.Utils.Networking.ProtocolTestUtils)
local CodecUtils = require(script.Parent.Utils.Networking.CodecTestUtils)
local Commands = require(script.Parent.Utils.Networking.CommandTestUtils)

local function manifest(): Commands.Manifest
	local metadata: any = ProtocolUtils.manifest()

	metadata.commands = {
		{
			id = "Game.Interact",
			code = 0,
			target = "Actor",
			request = Schema.Struct({ choice = Schema.Enum({ "Chest", "Door" }) }),
			result = Schema.Struct({ interactionInstanceId = Schema.U32 }),
		},
		{ id = "Game.Ping", code = 1, target = "None" },
	}

	return metadata
end

local function reconstruct(metadata: Commands.Manifest): Commands.Protocol
	local protocol: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(metadata)
	expect(reason).toBeNil()

	assert(
		protocol ~= nil,
		"[N9 missing contract] N2 must reconstruct command metadata alongside Actor domains (#79.5)"
	)

	local commandProtocol: Commands.Protocol = protocol :: any
	assert(commandProtocol.commandsById ~= nil, "[N9 missing contract] compiled command codebook (#79.5)")

	return commandProtocol
end

it("round trips command ids, codes, targets and optional schemas through the existing N2 Bootstrap", function()
	local metadata: Commands.Manifest = manifest()
	local encoded: buffer?, reason: string? = Codec.Encode({ kind = "Bootstrap", manifest = metadata })
	expect(reason).toBeNil()
	assert(encoded ~= nil, "[N9 missing contract] existing N2 Bootstrap must carry commands (#79.5)")
	expect(buffer.len(encoded) <= Constants.MAX_BOOTSTRAP_BYTES).toBe(true)
	local decoded: SharedTypes.ProtocolMessage = ProtocolUtils.decode(encoded)
	assert(decoded.kind == "Bootstrap", "Expected N2 Bootstrap")
	expect(decoded.manifest).toEqual(metadata)
	local protocol: Commands.Protocol = reconstruct(decoded.manifest :: any)
	local command: Commands.ClientCommand = protocol.commandsById["Game.Interact"]
	expect(command.id).toBe("Game.Interact")
	expect(command.target).toBe("Actor")
	expect(protocol.commandsByCode[command.code]).toBe(command)
end)

it("bootstraps empty commands with existing Actor domain and event metadata intact", function()
	local metadata: Commands.Manifest = manifest()
	metadata.commands = {}

	local protocol: Commands.Protocol = reconstruct(metadata)
	expect(protocol.commandsById).toEqual({})
	expect(protocol.commandsByCode).toEqual({})
	CodecUtils.expectRoundTrip(protocol.domainsById["Game.Actions"].stateCodec, { active = true, mode = "Blocking" })
	CodecUtils.expectRoundTrip(protocol.domainsById["Game.Actions"].eventsById.Changed.codec, { count = 17 })
	CodecUtils.expectRoundTrip(protocol.domainsById["Game.Inventory"].stateCodec, { "Potion" })
end)

it("builds reusable N1 request and result codecs with independent schema validation", function()
	local protocol: Commands.Protocol = reconstruct(manifest())
	local command: Commands.ClientCommand = protocol.commandsById["Game.Interact"]
	assert(command.requestCodec ~= nil and command.resultCodec ~= nil, "Expected both declared codecs")
	CodecUtils.expectRoundTrip(command.requestCodec, { choice = "Door" })
	CodecUtils.expectRoundTrip(command.resultCodec, { interactionInstanceId = 4294967295 })
	local size: number?, reason: string? = command.requestCodec.Measure({ choice = "Unknown" })
	expect(size).toBeNil()
	expect(type(reason)).toBe("string")
	size, reason = command.resultCodec.Measure({ interactionInstanceId = -1 })
	expect(size).toBeNil()
	expect(type(reason)).toBe("string")
	expect(protocol.commandsByCode[command.code].requestCodec).toBe(command.requestCodec)
	expect(table.isfrozen(command)).toBe(true)
	expect(table.isfrozen(protocol.commandsById)).toBe(true)
	expect(table.isfrozen(protocol.commandsByCode)).toBe(true)
end)

for _, optional: { boolean } in { { false, false }, { true, false }, { false, true }, { true, true } } do
	it(
		"supports independent request/result omission " .. tostring(optional[1]) .. "/" .. tostring(optional[2]),
		function()
			local metadata: Commands.Manifest = manifest()

			local command: Commands.ManifestCommand = metadata.commands[2]
			command.request = if optional[1] then Schema.Optional(Schema.U8) else nil
			command.result = if optional[2] then Schema.Optional(Schema.U16) else nil

			local protocol: Commands.Protocol = reconstruct(metadata)
			local installed: Commands.ClientCommand = protocol.commandsById[command.id]

			if optional[1] then
				assert(installed.requestCodec ~= nil, "An Optional schema is distinct from an omitted schema")
				CodecUtils.expectRoundTrip(installed.requestCodec, nil)
				CodecUtils.expectRoundTrip(installed.requestCodec, 7)
			else
				expect(installed.requestCodec).toBeNil()
			end

			if optional[2] then
				assert(installed.resultCodec ~= nil, "An Optional schema is distinct from an omitted schema")
				CodecUtils.expectRoundTrip(installed.resultCodec, nil)
				CodecUtils.expectRoundTrip(installed.resultCodec, 256)
			else
				expect(installed.resultCodec).toBeNil()
			end
		end
	)
end

it("bumps the kickoff version and rejects the old version even with valid command metadata", function()
	local metadata: Commands.Manifest = manifest()
	reconstruct(metadata)
	expect(Constants.PROTOCOL_VERSION > 4).toBe(true)
	metadata = { version = 4, domains = metadata.domains, commands = metadata.commands } :: any
	local protocol: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(metadata)
	expect(protocol).toBeNil()
	expect(reason).toBe("ProtocolMismatch")
end)

for _, invalid: any in
	{
		{ label = "duplicate id", index = 2, field = "id", value = "Game.Interact" },
		{ label = "duplicate code", index = 2, field = "code", value = 0 },
		{ label = "out-of-range code", index = 1, field = "code", value = 2 },
		{ label = "fractional code", index = 1, field = "code", value = 0.5 },
		{ label = "empty id", index = 1, field = "id", value = "" },
		{ label = "invalid target", index = 1, field = "target", value = "Owner" },
		{ label = "missing target", index = 1, field = "target" },
		{ label = "unbounded request", index = 1, field = "request", value = { kind = "String" } },
		{ label = "unbounded result", index = 1, field = "result", value = { kind = "Array" } },
		{ label = "serialized authorization", index = 1, field = "authorize", value = "OwnerActor" },
		{ label = "serialized handler", index = 1, field = "handle", value = "ServerFunction" },
	}
do
	it("rejects " .. invalid.label .. " after accepting a valid combined manifest", function()
		local metadata: Commands.Manifest = manifest()
		reconstruct(metadata)

		local command: any = metadata.commands[invalid.index]
		command[invalid.field] = invalid.value
		local protocol: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(metadata)
		expect(protocol).toBeNil()
		expect(type(reason)).toBe("string")
	end)
end

it("enforces one combined 65536-byte ceiling when domain-only and command-only manifests each fit", function()
	local domains: { SharedTypes.ManifestDomain } = {}
	local commands: { Commands.ManifestCommand } = {}

	for index: number = 1, 200 do
		local id: string = string.format("Game.%03d.%s", index, string.rep("x", 170))
		local domain: SharedTypes.ManifestDomain = { id = id, code = index - 1, state = Schema.U8, events = {} }
		table.insert(domains, domain)
		table.insert(commands, { id = id, code = index - 1, target = "None" })
	end

	for _, metadata: Commands.Manifest in
		{
			{ version = Constants.PROTOCOL_VERSION, domains = domains, commands = {} } :: any,
			{ version = Constants.PROTOCOL_VERSION, domains = {}, commands = commands } :: any,
		}
	do
		local encoded: buffer?, reason: string? = Codec.Encode({ kind = "Bootstrap", manifest = metadata })
		expect(reason).toBeNil()
		assert(encoded ~= nil, "Each half of the combined budget fixture must fit")
		expect(buffer.len(encoded) < Constants.MAX_BOOTSTRAP_BYTES).toBe(true)
	end

	local encoded: buffer?, reason: string? = Codec.Encode({
		kind = "Bootstrap",
		manifest = { version = Constants.PROTOCOL_VERSION, domains = domains, commands = commands } :: any,
	})

	-- Jest-Lua cannot pretty-print a buffer when a nil expectation fails.
	expect(encoded == nil).toBe(true)
	expect(reason).toBe("BootstrapTooLarge")
end)
