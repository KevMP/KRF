--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Schema: NetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: ProtocolTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)

local ProtocolTestUtils = {}

function ProtocolTestUtils.manifest(): ProtocolTypes.ProtocolManifest
	return {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.Actions",
				code = 0,
				state = Schema.Struct({ mode = Schema.Enum({ "Blocking", "Idle" }), active = Schema.Boolean }),
				events = { { id = "Changed", code = 0, payload = Schema.Struct({ count = Schema.U16 }) } },
			},
			{ id = "Game.Inventory", code = 1, state = Schema.Array(Schema.String(8), 2), events = {} },
		},
	}
end

function ProtocolTestUtils.encode(message: ProtocolTypes.Message): buffer
	local encoded: buffer?, reason: string? = Codec.Encode(message)
	expect(reason).toBeNil()
	assert(encoded ~= nil, "Expected a protocol buffer")
	return encoded
end

function ProtocolTestUtils.decode(payload: buffer): ProtocolTypes.Message
	local message: ProtocolTypes.Message?, reason: string? = Codec.Decode(payload)
	expect(reason).toBeNil()
	assert(message ~= nil, "Expected a protocol message")
	return message
end

return ProtocolTestUtils
