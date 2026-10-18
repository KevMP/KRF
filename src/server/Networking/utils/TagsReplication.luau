--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local TagTypes = require(script.Parent.Parent.Parent.Tags.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedTypes.Schema = require(script.Parent.Parent.Parent.Parent.shared.Networking.Schema)

export type ReplicatedTagState = { stackCount: number, expiresAt: number? }
export type ReplicatedTagsState = { [string]: ReplicatedTagState }

local TagsReplication = {}

-- Declaration scaffold for N6. Projection, mutation observation and timing are
-- intentionally unimplemented until the behavioral test baseline is reviewed.
function TagsReplication.Build(
	tags: { TagTypes.TagDefinition },
	_serverTimeNow: (() -> number)?
): ReplicationTypes.ReplicationDomainDefinition?
	local visibleIds: { string } = {}
	for _, definition: TagTypes.TagDefinition in tags do
		if definition.visibility == "ClientVisible" then
			table.insert(visibleIds, definition.id)
		end
	end
	if #visibleIds == 0 then
		return nil
	end
	table.sort(visibleIds)
	local tagId: SharedTypes.SchemaDefinition = Schema.Enum(visibleIds)
	return {
		id = "KRF.Tags",
		audience = "All",
		state = Schema.Map(
			tagId,
			Schema.Struct({ stackCount = Schema.U32, expiresAt = Schema.Optional(Schema.F64) }),
			#visibleIds
		),
		events = {
			{ id = "Added", payload = tagId },
			{ id = "Refreshed", payload = tagId },
			{ id = "Removed", payload = tagId },
			{ id = "Expired", payload = tagId },
		},
		snapshot = function(_actor: ActorTypes.Actor): ReplicatedTagsState
			return {}
		end,
		observe = function(
			_actor: ActorTypes.Actor,
			_onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
		): () -> ()
			return function(): () end
		end,
	}
end

return TagsReplication
