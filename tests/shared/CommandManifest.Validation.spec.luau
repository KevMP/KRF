--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local SharedTypes = require(KRF.shared.Networking.types)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Schema = require(KRF.shared.Networking.Schema)

local malformed: { { name: string, commands: any, reason: string? } } = {
	{ name = "non-array catalog", commands = false },
	{ name = "sparse catalog", commands = { [2] = { id = "Game.Ping", code = 0, target = "None" } } },
	{ name = "non-table entry", commands = { false } },
	{
		name = "numeric metadata field",
		commands = { { id = "Game.Ping", code = 0, target = "None", [1] = "Unexpected" } },
	},
	{
		name = "callbacks in metadata",
		commands = { { id = "Game.Ping", code = 0, target = "None", handle = function() end } },
	},
	{ name = "fractional code", commands = { { id = "Game.Ping", code = 0.5, target = "None" } } },
	{ name = "negative code", commands = { { id = "Game.Ping", code = -1, target = "None" } } },
	{
		name = "unsupported result schema",
		commands = { { id = "Game.Ping", code = 0, target = "None", result = { kind = "FutureSchema" } } },
		reason = "UnsupportedSchema",
	},
	{
		name = "invalid schema bounds",
		commands = { { id = "Game.Ping", code = 0, target = "None", request = { kind = "String", maxBytes = -1 } } },
	},
	{
		name = "oversized request",
		commands = { { id = "Game.Ping", code = 0, target = "None", request = Schema.String(16384) } },
		reason = "CommandPayloadTooLarge",
	},
	{
		name = "oversized result",
		commands = { { id = "Game.Ping", code = 0, target = "None", result = Schema.String(16384) } },
		reason = "CommandPayloadTooLarge",
	},
}

for _, invalid in malformed do
	it("rejects " .. invalid.name .. " before installing a command codebook", function()
		local protocol: SharedTypes.ClientProtocol?, reason: string? =
			Manifest.Reconstruct({ version = Constants.PROTOCOL_VERSION, domains = {}, commands = invalid.commands })

		expect(protocol).toBeNil()
		expect(reason).toBe(invalid.reason or "MalformedBootstrap")
	end)
end

it("bounds command metadata count independently of bootstrap byte size", function()
	local definitions: { SharedTypes.ManifestCommand } = {}

	for index: number = 1, 1025 do
		definitions[index] = { id = "Game.Ping", code = 0, target = "None" }
	end

	local protocol: SharedTypes.ClientProtocol?, reason: string? =
		Manifest.Reconstruct({ version = Constants.PROTOCOL_VERSION, domains = {}, commands = definitions })

	expect(protocol).toBeNil()
	expect(reason).toBe("MalformedBootstrap")
end)

it("fails reconstruction cleanly when a validated command codec cannot compile", function()
	local original: typeof(CodecCompiler.Compile) = CodecCompiler.Compile

	CodecCompiler.Compile = function(_schema: SharedTypes.CompiledSchema): (SharedTypes.CompiledCodec?, string?)
		return nil, "InjectedCommandCodecFailure"
	end

	local completed: boolean, failure: any = pcall(function()
		local protocol: SharedTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct({
			version = Constants.PROTOCOL_VERSION,
			domains = {},
			commands = { { id = "Game.Ping", code = 0, target = "None", result = Schema.U8 } },
		})

		expect(protocol).toBeNil()
		expect(reason).toBe("InjectedCommandCodecFailure")
	end)

	CodecCompiler.Compile = original

	if not completed then
		error(failure, 0)
	end
end)
