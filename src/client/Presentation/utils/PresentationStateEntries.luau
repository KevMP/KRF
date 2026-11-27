--!strict
local Types = require(script.Parent.Parent.types)
local StateSources = require(script.Parent.PresentationStateSources)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

export type StateEntryHost = {
	read IsReady: () -> boolean,
	read Start: (
		Types.PresentationDefinition,
		Types.PresentationStateEntry,
		() -> boolean
	) -> Types.PresentationContext?,
}

export type StateEntries = {
	read Schedule: () -> (),
	read Destroy: () -> (),
}

type Occurrence = { context: Types.PresentationContext? }

local StateEntries = {}

function StateEntries.new(
	actor: ActorTypes.ActorView,
	catalog: Types.PresentationStateCatalog,
	host: StateEntryHost
): StateEntries
	local destroyed: boolean = false
	local pending: boolean = false
	local tags: { [Types.PresentationDefinition]: Occurrence } = {}
	local actions: { [Types.PresentationDefinition]: { [number]: Occurrence } } = {}
	local schedule: () -> ()

	local function retire(occurrence: Occurrence): ()
		local context: Types.PresentationContext? = occurrence.context

		occurrence.context = nil

		if context ~= nil then
			context:Finish()
		end
	end

	local function start(
		definition: Types.PresentationDefinition,
		entry: Types.PresentationStateEntry,
		isPresent: () -> boolean,
		release: () -> ()
	): Occurrence
		local occurrence: Occurrence = { context = nil }

		occurrence.context = host.Start(definition, entry, function(): boolean
			if host.IsReady() and isPresent() then
				return true
			end

			release()
			schedule()

			return false
		end)

		return occurrence
	end

	local function reconcileTag(definitions: { Types.PresentationDefinition }, tagId: string): ()
		local snapshot: ActorTypes.ActiveTagSnapshot? = actor:GetTags():GetTag(tagId)

		for _, definition: Types.PresentationDefinition in definitions do
			local occurrence: Occurrence? = tags[definition]

			if snapshot == nil then
				if occurrence ~= nil then
					tags[definition] = nil
					retire(occurrence)
				end
			elseif occurrence == nil then
				local entry: Types.TagStateEntry = table.freeze({
					source = "State" :: "State",
					kind = "Tag" :: "Tag",
					actor = actor,
					tagId = tagId,
					tag = snapshot,
				})

				tags[definition] = start(definition, entry, function(): boolean
					return actor:GetTags():HasTag(tagId)
				end, function(): ()
					tags[definition] = nil
				end)
			end
		end
	end

	local function reconcileAction(definitions: { Types.PresentationDefinition }, actionId: string): ()
		local present: { [number]: boolean } = {}
		local snapshots: { ActorTypes.ActionSnapshot } = {}

		for _, snapshot: ActorTypes.ActionSnapshot in actor:GetActions():GetActiveActions() do
			if snapshot.actionId == actionId then
				present[snapshot.sequenceId] = true
				table.insert(snapshots, snapshot)
			end
		end

		for _, definition: Types.PresentationDefinition in definitions do
			local bySequence: { [number]: Occurrence } = actions[definition] or {}

			actions[definition] = bySequence

			for sequenceId: number, occurrence: Occurrence in table.clone(bySequence) do
				if not present[sequenceId] then
					bySequence[sequenceId] = nil
					retire(occurrence)
				end
			end

			for _, snapshot: ActorTypes.ActionSnapshot in snapshots do
				local sequenceId: number = snapshot.sequenceId

				if bySequence[sequenceId] == nil then
					local entry: Types.ActionStateEntry = table.freeze({
						source = "State" :: "State",
						kind = "Action" :: "Action",
						actor = actor,
						action = snapshot,
					})

					bySequence[sequenceId] = start(definition, entry, function(): boolean
						return StateSources.IsActionActive(actor, actionId, sequenceId)
					end, function(): ()
						bySequence[sequenceId] = nil
					end)
				end
			end
		end
	end

	local function reconcile(): ()
		pending = false

		if destroyed or not host.IsReady() then
			return
		end

		for descriptor: Types.PresentationStateEntryDescriptor, bySourceId in catalog do
			for sourceId: string, definitions: { Types.PresentationDefinition } in bySourceId do
				if descriptor.source == "Tag" then
					reconcileTag(definitions, sourceId)
				else
					reconcileAction(definitions, sourceId)
				end
			end
		end
	end

	schedule = function(): ()
		if not destroyed and not pending then
			pending = true
			task.defer(reconcile)
		end
	end

	return table.freeze({
		Schedule = schedule,
		Destroy = function(): ()
			destroyed = true
			table.clear(tags)
			table.clear(actions)
		end,
	})
end

return table.freeze(StateEntries)
