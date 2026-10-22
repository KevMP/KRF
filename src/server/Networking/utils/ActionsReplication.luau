--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local ActionTypes = require(script.Parent.Parent.Parent.Action.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedTypes.Schema = require(script.Parent.Parent.Parent.Parent.shared.Networking.Schema)

type State = { [number]: string }
type Projection = { state: State, count: number, snapshot: State?, observed: boolean, invalid: boolean }
type Update = { actionId: string? }

local ActionsReplication = {}

local function validSequence(sequenceId: number): boolean
	return sequenceId >= 1 and sequenceId <= 4294967295 and sequenceId % 1 == 0
end

function ActionsReplication.Build(
	actions: { ActionTypes.LoadedActionDefinition }
): ReplicationTypes.ReplicationDomainDefinition?
	local visibleIds: { string } = {}
	local visibility: { [string]: boolean } = {}

	for _, definition: ActionTypes.LoadedActionDefinition in actions do
		visibility[definition.id] = definition.visibility == "ClientVisible"

		if definition.visibility == "ClientVisible" then
			table.insert(visibleIds, definition.id)
		end
	end

	if #visibleIds == 0 then
		return nil
	end

	table.sort(visibleIds)
	local actionId: SharedTypes.SchemaDefinition = Schema.Enum(visibleIds)
	local identity: SharedTypes.SchemaDefinition = Schema.Struct({ actionId = actionId, sequenceId = Schema.U32 })
	local projections: { [ActorTypes.Actor]: Projection } = setmetatable({}, { __mode = "k" })

	local function controllerFor(actor: ActorTypes.Actor): ActionTypes.InternalActionController
		local controller: ActionTypes.InternalActionController? =
			actor:GetController("ActionController") :: ActionTypes.InternalActionController?

		assert(controller ~= nil, "ActionsReplicationMissingActionController")

		return controller
	end

	local function initialize(actor: ActorTypes.Actor): Projection
		local state: State = {}
		local seen: { [number]: boolean } = {}
		local count: number = 0

		for _, entry: ActionTypes.ActionReplicationIdentity in controllerFor(actor):_getActiveReplicationState() do
			assert(
				validSequence(entry.sequenceId) and not seen[entry.sequenceId] and visibility[entry.actionId] ~= nil,
				"ActionsReplicationInvalidState"
			)

			seen[entry.sequenceId] = true

			if visibility[entry.actionId] then
				count += 1
				assert(count <= 256, "ActionsReplicationInvalidState")
				state[entry.sequenceId] = entry.actionId
			end
		end

		local projection: Projection =
			{ state = state, count = count, snapshot = nil, observed = false, invalid = false }

		projections[actor] = projection

		return projection
	end

	return {
		id = "KRF.Actions",
		audience = "All",
		state = Schema.Map(Schema.U32, actionId, 256),
		events = {
			{ id = "Started", payload = identity },
			{ id = "Ended", payload = identity },
			{ id = "Interrupted", payload = identity },
		},
		snapshot = function(actor: ActorTypes.Actor): State
			local existing: Projection? = projections[actor]
			local projection: Projection = if existing ~= nil and existing.observed then existing else initialize(actor)
			assert(not projection.invalid, "ActionsReplicationInvalidState")

			if projection.snapshot == nil then
				projection.snapshot = table.freeze(table.clone(projection.state))
			end

			return projection.snapshot :: State
		end,
		observe = function(
			actor: ActorTypes.Actor,
			onCommitted: ReplicationTypes.ReplicationDomainOnCommitted
		): () -> ()
			local controller: ActionTypes.InternalActionController = controllerFor(actor)
			local projection: Projection = projections[actor] or initialize(actor)
			assert(not projection.observed, "ActionsReplicationAlreadyObserved")
			projection.observed = true

			local active: boolean = true

			local disconnect: () -> () = controller:_observeMutations(
				function(mutations: { ActionTypes.ActionReplicationMutation }): ()
					if not active then
						return
					end

					local events: { ReplicationTypes.ReplicationDomainEvent } = {}
					local updates: { [number]: Update } = {}
					local count: number = projection.count
					local invalid: boolean = projection.invalid

					for _, mutation: ActionTypes.ActionReplicationMutation in mutations do
						-- A private-only batch does no projection or downstream work.
						if visibility[mutation.actionId] ~= false then
							if not validSequence(mutation.sequenceId) then
								invalid = true
							else
								local pending: Update? = updates[mutation.sequenceId]

								local previous: string? = if pending ~= nil
									then pending.actionId
									else projection.state[mutation.sequenceId]

								invalid = invalid or visibility[mutation.actionId] == nil

								if mutation.kind == "Started" then
									invalid = invalid or previous ~= nil
									count += if previous == nil then 1 else 0
									updates[mutation.sequenceId] = { actionId = mutation.actionId }
								else
									invalid = invalid or previous ~= mutation.actionId
									count -= if previous ~= nil then 1 else 0
									updates[mutation.sequenceId] = {}
								end
							end

							table.insert(events, {
								id = mutation.kind,
								payload = table.freeze({
									actionId = mutation.actionId,
									sequenceId = mutation.sequenceId,
								}),
							})
						end
					end

					if #events == 0 then
						return
					end

					projection.invalid = invalid or count > 256

					if not projection.invalid then
						for sequenceId: number, update: Update in updates do
							projection.state[sequenceId] = update.actionId
						end

						projection.count = count
						projection.snapshot = nil
					end

					-- Touch N3 even for invalid truth: its capture rejects the whole group.
					onCommitted(events)
				end
			)

			return function(): ()
				if active then
					active = false
					disconnect()
					projections[actor] = nil
				end
			end
		end,
	}
end

return ActionsReplication
