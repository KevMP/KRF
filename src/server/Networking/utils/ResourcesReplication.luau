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

type Projection = {
	state: ReplicatedResourcesState,
	snapshot: ReplicatedResourcesState?,
	observed: boolean,
	dirty: { [string]: boolean },
	invalid: boolean,
}

local Workspace: Workspace = game:GetService("Workspace")

local ResourcesReplication = {}

local function valid(entry: ReplicatedResourceState): boolean
	return math.isfinite(entry.anchorValue)
		and math.isfinite(entry.anchorTime)
		and math.isfinite(entry.min)
		and math.isfinite(entry.max)
		and (entry.regenRate == nil or math.isfinite(entry.regenRate))
		and entry.min <= entry.max
		and entry.anchorValue >= entry.min
		and entry.anchorValue <= entry.max
end

local function anchor(state: ResourceTypes.ResourceReplicationState, serverTime: number): ReplicatedResourceState
	return table.freeze({
		anchorValue = state.current,
		anchorTime = serverTime,
		min = state.min,
		max = state.max,
		regenRate = state.regenRate,
	})
end

function ResourcesReplication.Build(
	resources: { ResourceTypes.LoadedResourceDefinition },
	serverTimeNow: (() -> number)?
): ReplicationTypes.ReplicationDomainDefinition?
	local visibleIds: { string } = {}
	local visible: { [string]: boolean } = {}

	for _, definition: ResourceTypes.LoadedResourceDefinition in resources do
		if definition.visibility == "ClientVisible" then
			table.insert(visibleIds, definition.id)
			visible[definition.id] = true
		end
	end

	if #visibleIds == 0 then
		return nil
	end

	table.sort(visibleIds)

	local now: () -> number = serverTimeNow or function(): number
		return Workspace:GetServerTimeNow()
	end

	-- Initial captures are not observed until N3 admits the Actor. Weak keys also
	-- release rejected admissions which never reached observer installation.
	local projections: { [ActorTypes.Actor]: Projection } = setmetatable({}, { __mode = "k" })

	local function controllerFor(actor: ActorTypes.Actor): ResourceTypes.InternalResourceController
		local controller: ResourceTypes.InternalResourceController? =
			actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController?

		assert(controller ~= nil, "ResourcesReplicationMissingResourceController")

		return controller
	end

	local function initialize(actor: ActorTypes.Actor): Projection
		local controller: ResourceTypes.InternalResourceController = controllerFor(actor)
		local state: ReplicatedResourcesState = {}
		local serverTime: number? = nil

		for _, id: string in visibleIds do
			local current: ResourceTypes.ResourceReplicationState? = controller:_getReplicationState(id)

			if current ~= nil then
				if serverTime == nil then
					serverTime = now()
				end

				local entry: ReplicatedResourceState = anchor(current, serverTime :: number)
				assert(valid(entry), "ResourcesReplicationInvalidState")
				state[id] = entry
			end
		end

		local projection: Projection = { state = state, snapshot = nil, observed = false, dirty = {}, invalid = false }

		projections[actor] = projection

		return projection
	end

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
		snapshot = function(actor: ActorTypes.Actor): ReplicatedResourcesState
			local existing: Projection? = projections[actor]
			local projection: Projection = if existing ~= nil and existing.observed then existing else initialize(actor)
			assert(not projection.invalid, "ResourcesReplicationInvalidState")
			local captured: ReplicatedResourcesState? = projection.snapshot

			if captured ~= nil then
				return captured
			end

			local frozen: ReplicatedResourcesState = table.freeze(table.clone(projection.state))

			projection.snapshot = frozen

			return frozen
		end,
		observe = function(
			actor: ActorTypes.Actor,
			onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
		): () -> ()
			local controller: ResourceTypes.InternalResourceController = controllerFor(actor)
			local projection: Projection = projections[actor] or initialize(actor)
			assert(not projection.observed, "ResourcesReplicationAlreadyObserved")
			projection.observed = true

			local active: boolean = true

			local disconnect: () -> () = controller:_observeMutations({
				includeRegenSteps = false,
				Commit = function(mutations: { ResourceTypes.ResourceMutation }): ()
					local meaningful: boolean = false

					for _, mutation: ResourceTypes.ResourceMutation in mutations do
						if mutation.kind ~= "RegenStep" and visible[mutation.resourceId] then
							projection.dirty[mutation.resourceId] = true
							meaningful = true
						end
					end

					-- Filter before all projection work, including retries of a rejected capture.
					if not meaningful then
						return
					end

					local ids: { string } = {}

					for id: string in projection.dirty do
						table.insert(ids, id)
					end

					table.sort(ids)
					local serverTime: number = now()
					local updates: ReplicatedResourcesState = {}
					local invalid: boolean = false

					for _, id: string in ids do
						local current: ResourceTypes.ResourceReplicationState? = controller:_getReplicationState(id)

						if current ~= nil then
							local entry: ReplicatedResourceState = anchor(current, serverTime)

							updates[id] = entry
							invalid = invalid or not valid(entry)
						end
					end

					projection.invalid = invalid

					if not invalid then
						for _, id: string in ids do
							projection.state[id] = updates[id]
						end

						table.clear(projection.dirty)
						projection.snapshot = nil
					end

					-- Even a rejected capture must touch N3 so a grouped sibling domain
					-- cannot publish on its own. snapshot reports the fault through N3.
					onCommitted()
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

return ResourcesReplication
