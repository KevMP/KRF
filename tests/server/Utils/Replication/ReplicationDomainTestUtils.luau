--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)

local Registry: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local ReplicationDomainTestUtils = {}

function ReplicationDomainTestUtils.createDomain(id: string): ReplicationTypes.ReplicationDomainDefinition
	return {
		id = id,
		state = Schema.Struct({ active = Schema.Boolean }),
		snapshot = function(_actor: ActorTypes.Actor): any
			return { active = false }
		end,
	}
end

function ReplicationDomainTestUtils.prepare(
	definitions: { ReplicationTypes.ReplicationDomainDefinition }
): ReplicationTypes.PreparedReplicationDomainCatalog
	local prepared: ReplicationTypes.PreparedReplicationDomainCatalog?, reason: string? = Registry.Prepare(definitions)
	expect(reason).toBeNil()
	expect(prepared).never.toBeNil()

	return prepared :: ReplicationTypes.PreparedReplicationDomainCatalog
end

function ReplicationDomainTestUtils.load(definitions: { ReplicationTypes.ReplicationDomainDefinition }): ()
	local prepared: ReplicationTypes.PreparedReplicationDomainCatalog = ReplicationDomainTestUtils.prepare(definitions)
	local loaded: boolean, reason: string? = Registry.Publish(prepared)
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end

return ReplicationDomainTestUtils
