--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local TagTypes = require(script.Parent.Parent.Parent.Tags.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedTypes.Schema = require(script.Parent.Parent.Parent.Parent.shared.Networking.Schema)

export type ReplicatedTagState = { read stackCount: number, read expiresAt: number? }
export type ReplicatedTagsState = { [string]: ReplicatedTagState }

type Projection = {
	state: ReplicatedTagsState,
	snapshot: ReplicatedTagsState?,
	observed: boolean,
}

local Workspace: Workspace = game:GetService("Workspace")

local TagsReplication = {}

function TagsReplication.Build(
	tags: { TagTypes.TagDefinition },
	serverTimeNow: (() -> number)?
): ReplicationTypes.ReplicationDomainDefinition?
	local visibleIds: { string } = {}
	local visible: { [string]: boolean } = {}

	for _, definition: TagTypes.TagDefinition in tags do
		if definition.visibility == "ClientVisible" then
			table.insert(visibleIds, definition.id)
			visible[definition.id] = true
		end
	end

	if #visibleIds == 0 then
		return nil
	end

	table.sort(visibleIds)
	local tagId: SharedTypes.SchemaDefinition = Schema.Enum(visibleIds)

	local now: () -> number = serverTimeNow or function(): number
		return Workspace:GetServerTimeNow()
	end

	-- Pending initial captures do not own an observer. Weak Actor keys release
	-- them if N3 rejects initial admission before observe can install cleanup.
	local projections: { [ActorTypes.Actor]: Projection } = setmetatable({}, { __mode = "k" })

	local function controllerFor(actor: ActorTypes.Actor): TagTypes.InternalTagController
		local controller: TagTypes.InternalTagController? =
			actor:GetController("TagController") :: TagTypes.InternalTagController?

		assert(controller ~= nil, "TagsReplicationMissingTagController")

		return controller
	end

	local function entry(stackCount: number, remainingDuration: number?): ReplicatedTagState
		return table.freeze({
			stackCount = stackCount,
			expiresAt = if remainingDuration ~= nil then now() + remainingDuration else nil,
		})
	end

	local function initialize(actor: ActorTypes.Actor): Projection
		local state: ReplicatedTagsState = {}

		for _, active: TagTypes.ActiveTagSnapshot in controllerFor(actor):GetActiveTags() do
			if visible[active.tagId] then
				state[active.tagId] = entry(active.stackCount, active.remainingDuration)
			end
		end

		local projection: Projection = { state = state, snapshot = nil, observed = false }

		projections[actor] = projection

		return projection
	end

	local function currentEntry(controller: TagTypes.InternalTagController, id: string): ReplicatedTagState?
		local instances: { TagTypes.TagInstanceSnapshot } = controller:GetTagInstances(id)

		if #instances == 0 then
			return nil
		end

		local longest: number? = nil

		for _, instance: TagTypes.TagInstanceSnapshot in instances do
			local remaining: number? = instance.remainingDuration

			if remaining ~= nil and (longest == nil or remaining > longest) then
				longest = remaining
			end
		end

		return entry(#instances, longest)
	end

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
		snapshot = function(actor: ActorTypes.Actor): ReplicatedTagsState
			-- A rejected initial capture must be retryable against current truth.
			local existing: Projection? = projections[actor]
			local projection: Projection = if existing ~= nil and existing.observed then existing else initialize(actor)
			local captured: ReplicatedTagsState? = projection.snapshot

			if captured ~= nil then
				return captured
			end

			local frozen: ReplicatedTagsState = table.freeze(table.clone(projection.state))

			projection.snapshot = frozen

			return frozen
		end,
		observe = function(
			actor: ActorTypes.Actor,
			onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
		): () -> ()
			local controller: TagTypes.InternalTagController = controllerFor(actor)
			local projection: Projection = projections[actor] or initialize(actor)
			assert(not projection.observed, "TagsReplicationAlreadyObserved")
			projection.observed = true

			local active: boolean = true

			local disconnect: () -> () = controller:_observeMutations({
				Commit = function(mutations: { TagTypes.TagMutationEvent }): ()
					local events: { ReplicationTypes.ReplicationDomainEvent } = {}
					local touched: { string } = {}
					local seen: { [string]: boolean } = {}

					for _, mutation: TagTypes.TagMutationEvent in mutations do
						if visible[mutation.tagId] then
							table.insert(events, { id = mutation.kind, payload = mutation.tagId })

							if not seen[mutation.tagId] then
								seen[mutation.tagId] = true
								table.insert(touched, mutation.tagId)
							end
						end
					end

					if #events == 0 then
						return
					end

					local updates: ReplicatedTagsState = {}

					for _, id: string in touched do
						updates[id] = currentEntry(controller, id)
					end

					for _, id: string in touched do
						projection.state[id] = updates[id]
					end

					projection.snapshot = nil
					onCommitted(events)
				end,
				Dispatch = function(): () end,
			})

			return function(): ()
				if not active then
					return
				end

				active = false
				disconnect()
				projections[actor] = nil
			end
		end,
	}
end

return TagsReplication
