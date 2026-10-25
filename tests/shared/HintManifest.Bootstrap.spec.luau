--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.shared.Networking.types)
local Schema: Types.Schema = require(KRF.shared.Networking.Schema)
local Protocol: Types.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Compiler = require(KRF.shared.Networking.CodecCompiler)
local SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Hints = require(KRF.shared.Networking.utils.HintConstants)
local ProtocolUtils = require(script.Parent.Utils.Networking.ProtocolTestUtils)
local originalCompile: typeof(Compiler.Compile) = Compiler.Compile

afterEach(function()
	Compiler.Compile = originalCompile
end)

local function metadata(): Types.ProtocolManifest
	return {
		version = Constants.PROTOCOL_VERSION,
		domains = {},
		hints = {
			{
				id = "Game.Look",
				code = 0,
				direction = "ClientToServer",
				target = "Actor",
				mode = "Latest",
				payload = Schema.U8,
			},
			{
				id = "Game.VFX",
				code = 1,
				direction = "ServerToClient",
				target = "None",
				mode = "Pulse",
				payload = Schema.U16,
			},
		},
	}
end

it("reconstructs frozen bidirectional Hint payload codebooks alongside existing domain and command metadata", function()
	local source: any = ProtocolUtils.manifest()
	source.hints = metadata().hints
	source.commands = { { id = "Game.Ping", code = 0, target = "None" } }

	local encoded = ProtocolUtils.encode({ kind = "Bootstrap", manifest = source })
	local decoded = ProtocolUtils.decode(encoded)
	assert(decoded.kind == "Bootstrap", "Expected bootstrap")
	expect(decoded.manifest).toEqual(source)
	local runtime, reason = Manifest.Reconstruct(decoded.manifest)
	expect(reason).toBeNil()
	assert(runtime ~= nil and runtime.hintsById ~= nil and runtime.hintsByCode ~= nil, "Expected Hint codebooks")
	local hint = runtime.hintsById["Game.Look"]
	expect(runtime.hintsByCode[0]).toBe(hint)
	expect(hint.payloadCodec.Measure(255)).toBe(1)
	expect(table.isfrozen(runtime)).toBe(true)
	expect(table.isfrozen(runtime.hintsById)).toBe(true)
	expect(table.isfrozen(runtime.hintsByCode)).toBe(true)
	expect(table.isfrozen(hint)).toBe(true)
	expect(runtime.domainsById["Game.Actions"].stateCodec.maxSizeBytes > 0).toBe(true)
	assert(runtime.commandsById ~= nil, "Expected existing command codebook")
	expect(runtime.commandsById["Game.Ping"].code).toBe(0)
end)

for _, invalid: any in
	{
		{ label = "duplicate id", index = 2, field = "id", value = "Game.Look" },
		{ label = "duplicate code", index = 2, field = "code", value = 0 },
		{ label = "empty id", index = 1, field = "id", value = "" },
		{ label = "non-string id", index = 1, field = "id", value = false },
		{ label = "missing code", index = 1, field = "code" },
		{ label = "fractional code", index = 1, field = "code", value = 0.5 },
		{ label = "code beyond catalog", index = 1, field = "code", value = 2 },
		{ label = "invalid direction", index = 1, field = "direction", value = "Both" },
		{ label = "invalid target", index = 1, field = "target", value = "Owner" },
		{ label = "invalid mode", index = 1, field = "mode", value = "Reliable" },
		{ label = "unbounded payload", index = 1, field = "payload", value = { kind = "String" } },
		{ label = "missing payload", index = 1, field = "payload" },
		{
			label = "unknown schema",
			index = 1,
			field = "payload",
			value = { kind = "Future" },
			reason = "UnsupportedSchema",
		},
		{
			label = "oversized record",
			index = 1,
			field = "payload",
			value = Schema.String(1000),
			reason = "HintRecordTooLarge",
		},
		{ label = "serialized authorization", index = 1, field = "authorize", value = "OwnerActor" },
		{ label = "serialized receiver", index = 1, field = "receive", value = "ServerCallback" },
		{ label = "non-string field", index = 1, field = 1, value = true },
	}
do
	it("rejects " .. invalid.label .. " without installing a partial Hint protocol", function()
		local source: any = metadata()
		source.hints[invalid.index][invalid.field] = invalid.value
		local runtime, reason = Manifest.Reconstruct(source)
		expect(runtime).toBeNil()
		expect(reason).toBe(invalid.reason or "MalformedBootstrap")
	end)
end

for _, invalid: any in { false, { [2] = assert(metadata().hints)[1] }, { false } } do
	it("rejects malformed Hint catalog shape " .. tostring(invalid), function()
		local source: any = metadata()
		source.hints = invalid
		local runtime, reason = Manifest.Reconstruct(source)
		expect(runtime).toBeNil()
		expect(reason).toBe("MalformedBootstrap")
	end)
end

it("bounds Hint catalog size independently of the bootstrap byte ceiling", function()
	local source: any = metadata()
	source.hints = table.create(Hints.MAX_HINTS + 1, source.hints[1])
	local runtime, reason = Manifest.Reconstruct(source)
	expect(runtime).toBeNil()
	expect(reason).toBe("MalformedBootstrap")
end)

for _, target: Types.HintTarget in { "None", "Actor" } do
	for _, mode: Types.HintMode in { "Latest", "Pulse" } do
		it("counts all envelope, handle and sequence bytes for " .. target .. " " .. mode .. " admission", function()
			expect(Hints.MAX_PACKET_BYTES <= 1000).toBe(true)

			local minimum = assert(SchemaCompiler.Compile(Schema.String(1)))

			local maximumString = Hints.MAX_PACKET_BYTES
				- Hints.PACKET_HEADER_BYTES
				- Hints.RecordBytes(minimum.maxEncodedBytes - 1, target, mode)

			for _, extra in { -1, 0, 1 } do
				local source: any = metadata()
				source.hints = { source.hints[1] }
				source.hints[1].target, source.hints[1].mode = target, mode
				source.hints[1].payload = Schema.String(maximumString + extra)
				local runtime, reason = Manifest.Reconstruct(source)

				if extra == 1 then
					expect(runtime).toBeNil()
					expect(reason).toBe("HintRecordTooLarge")
				else
					assert(runtime ~= nil and runtime.hintsById ~= nil, "Expected fitting Hint record")
					expect(reason).toBeNil()
					local codec = runtime.hintsById["Game.Look"].payloadCodec

					expect(
						Hints.PACKET_HEADER_BYTES + Hints.RecordBytes(codec.maxSizeBytes, target, mode)
							<= Hints.MAX_PACKET_BYTES
					).toBe(true)
				end
			end
		end)
	end
end

it("does not publish codebooks when an N2 payload codec cannot compile", function()
	Compiler.Compile = function(): (Types.CompiledCodec?, string?)
		return nil, "InjectedCodecFailure"
	end

	local runtime, reason = Manifest.Reconstruct(metadata())
	expect(runtime).toBeNil()
	expect(reason).toBe("InjectedCodecFailure")
end)

it("rejects truncation at every Hint bootstrap boundary and invalid wire enum tags", function()
	local source: any = metadata()
	source.hints = { source.hints[1] }

	local encoded = ProtocolUtils.encode({ kind = "Bootstrap", manifest = source })

	for length = 0, buffer.len(encoded) - 1 do
		local truncated = buffer.create(length)
		buffer.copy(truncated, 0, encoded, 0, length)
		local decoded, reason = Protocol.Decode(truncated)
		expect(decoded).toBeNil()
		expect(reason).toBe("MalformedPacket")
	end

	local directionOffset = 15 + 4 + #source.hints[1].id + 2

	for offset = directionOffset, directionOffset + 2 do
		local malformed = buffer.create(buffer.len(encoded))
		buffer.copy(malformed, 0, encoded)
		buffer.writeu8(malformed, offset, 2)
		local decoded, reason = Protocol.Decode(malformed)
		expect(decoded).toBeNil()
		expect(reason).toBe("MalformedPacket")
	end
end)

for _, invalid: any in
	{
		{ field = "direction", value = "Both" },
		{ field = "target", value = "Player" },
		{ field = "mode", value = "Reliable" },
		{ field = "authorize", value = true },
		{ field = "receive", value = true },
		{ field = 1, value = true },
	}
do
	it("refuses invalid Hint wire metadata " .. tostring(invalid.field) .. " during encoding", function()
		local source: any = metadata()
		source.hints[1][invalid.field] = invalid.value
		local encoded, reason = Protocol.Encode({ kind = "Bootstrap", manifest = source })
		expect(encoded == nil).toBe(true)
		expect(reason).toBe("InvalidProtocolManifest")
	end)
end

it("rejects a sparse Hint catalog during encoding", function()
	local source: any = metadata()
	source.hints[1] = nil
	local encoded, reason = Protocol.Encode({ kind = "Bootstrap", manifest = source })
	expect(encoded == nil).toBe(true)
	expect(reason).toBe("InvalidProtocolManifest")
end)

it("enforces a single bootstrap byte budget across domains, commands and Hints", function()
	local source: any = ProtocolUtils.manifest()
	source.commands, source.hints = {}, {}

	for index = 1, 200 do
		local id = string.format("Game.%03d.%s", index, string.rep("x", 170))
		table.insert(source.commands, { id = id, code = index - 1, target = "None" })

		table.insert(source.hints, {
			id = id,
			code = index - 1,
			direction = "ServerToClient",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
		})
	end

	for _, field in { "commands", "hints" } do
		local half: any = { version = source.version, domains = source.domains }
		half[field] = source[field]
		local encoded, reason = Protocol.Encode({ kind = "Bootstrap", manifest = half })
		expect(encoded ~= nil).toBe(true)
		expect(reason).toBeNil()
	end

	local encoded, reason = Protocol.Encode({ kind = "Bootstrap", manifest = source })
	expect(encoded == nil).toBe(true)
	expect(reason).toBe("BootstrapTooLarge")
end)

it("rejects the previous protocol version rather than interpreting it without Hint metadata", function()
	local source: any = metadata()
	source.version = 5
	local runtime, reason = Manifest.Reconstruct(source)
	expect(runtime).toBeNil()
	expect(reason).toBe("ProtocolMismatch")
	local encoded = ProtocolUtils.encode({ kind = "Bootstrap", manifest = source })
	local decoded, decodeReason = Protocol.Decode(encoded)
	expect(decoded).toBeNil()
	expect(decodeReason).toBe("ProtocolMismatch")
end)
