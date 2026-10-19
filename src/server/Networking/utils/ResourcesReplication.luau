--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ResourceTypes = require(script.Parent.Parent.Parent.Resource.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedTypes.Schema = require(script.Parent.Parent.Parent.Parent.shared.Networking.Schema)

export type ReplicatedResourceState = {
	read anchorValue: number,
	read anchorTime: number,
	read min: number,
	read max: number,
	read regenRate: number?,
}

export type ReplicatedResourcesState = { [string]: ReplicatedResourceState }

local ResourcesReplication = {}

function ResourcesReplication.Build(
	resources: { ResourceTypes.LoadedResourceDefinition },
	_serverTimeNow: (() -> number)?
): ReplicationTypes.ReplicationDomainDefinition?
	local visibleIds: { string } = {}

	for _, definition: ResourceTypes.LoadedResourceDefinition in resources do
		if definition.visibility == "ClientVisible" then
			table.insert(visibleIds, definition.id)
		end
	end

	if #visibleIds == 0 then
		return nil
	end

	table.sort(visibleIds)

	-- Static domain declaration only. N7 anchor capture and committed observation are TDD stubs.
	return {
		id = "KRF.Resources",
		audience = "All",
		state = Schema.Map(
			Schema.Enum(visibleIds),
			Schema.Struct({
				anchorValue = Schema.F64,
				anchorTime = Schema.F64,
				min = Schema.F64,
				max = Schema.F64,
				regenRate = Schema.Optional(Schema.F64),
			}),
			#visibleIds
		),
		events = {},
		snapshot = function(_actor: ActorTypes.Actor): ReplicatedResourcesState
			return table.freeze({} :: ReplicatedResourcesState)
		end,
		observe = function(
			_actor: ActorTypes.Actor,
			_onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
		): () -> ()
			return function(): () end
		end,
	}
end

return ResourcesReplication
