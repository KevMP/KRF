--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local DomainTestUtils = require(script.Parent.Parent.Replication.ReplicationDomainTestUtils)

local ServerProtocolTestUtils = {}

function ServerProtocolTestUtils.prepare(
	definitions: { ReplicationTypes.ReplicationDomainDefinition }
): SharedNetworkingTypes.PreparedProtocol
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainTestUtils.prepare(definitions)
	local protocol: SharedNetworkingTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected prepared server protocol")

	return protocol
end

return ServerProtocolTestUtils
