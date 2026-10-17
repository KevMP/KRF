--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Runtime: ServerNetworkingTypes.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local DomainTestUtils = require(script.Parent.Parent.Replication.ReplicationDomainTestUtils)

export type DomainFixture = {
	definition: ReplicationTypes.ReplicationDomainDefinition,
	value: any,
	snapshotCalls: number,
	disconnectCalls: number,
	callbacks: { [ActorTypes.Actor]: ReplicationTypes.ReplicationDomainOnCommitted },
}

local PublicationTestUtils = {}

function PublicationTestUtils.createDomain(
	id: string,
	schema: SharedNetworkingTypes.SchemaDefinition,
	value: any
): DomainFixture
	local fixture: DomainFixture = {
		definition = {
			id = id,
			state = schema,
			snapshot = function(): any
				return nil
			end,
		},
		value = value,
		snapshotCalls = 0,
		disconnectCalls = 0,
		callbacks = {},
	}
	fixture.definition.snapshot = function(_actor: ActorTypes.Actor): any
		fixture.snapshotCalls += 1
		return fixture.value
	end
	fixture.definition.observe = function(
		actor: ActorTypes.Actor,
		onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
	): () -> ()
		fixture.callbacks[actor] = onCommitted
		return function(): ()
			fixture.disconnectCalls += 1
			-- Deliberately retain the producer callback to test stale-callback safety.
		end
	end
	return fixture
end

function PublicationTestUtils.createRuntime(
	definitions: { ReplicationTypes.ReplicationDomainDefinition },
	options: ServerNetworkingTypes.PublicationRuntimeOptions?
): ServerNetworkingTypes.PublicationRuntime
	return Runtime.new(DomainTestUtils.prepare(definitions), options)
end

return PublicationTestUtils
