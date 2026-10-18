--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: SharedNetworkingTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)

local ProtocolTestUtils = {}

function ProtocolTestUtils.createPlayer(): Player
	-- Studio's test runner cannot create Players without WritePlayer capability.
	-- Injected transports need only an Instance identity and teardown; native
	-- Player delivery is exercised separately in the engine integration check.
	local identity: Folder = Instance.new("Folder")
	return identity :: any
end

function ProtocolTestUtils.manifest(): SharedNetworkingTypes.ProtocolManifest
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

function ProtocolTestUtils.encode(message: SharedNetworkingTypes.ProtocolMessage): buffer
	local encoded: buffer?, reason: string? = Codec.Encode(message)
	expect(reason).toBeNil()
	assert(encoded ~= nil, "Expected a protocol buffer")
	return encoded
end

function ProtocolTestUtils.decode(payload: buffer): SharedNetworkingTypes.ProtocolMessage
	local message: SharedNetworkingTypes.ProtocolMessage?, reason: string? = Codec.Decode(payload)
	expect(reason).toBeNil()
	assert(message ~= nil, "Expected a protocol message")
	return message
end

return ProtocolTestUtils
