--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local DomainTestUtils = require(script.Parent.Parent.Replication.ReplicationDomainTestUtils)

local ServerProtocolTestUtils = {}

function ServerProtocolTestUtils.prepare(
	definitions: { ReplicationTypes.ReplicationDomainDefinition }
): ProtocolTypes.PreparedProtocol
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare(definitions)
	local protocol: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected prepared server protocol")
	return protocol
end

return ServerProtocolTestUtils
