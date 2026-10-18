--!strict
local Types = require(script.Parent.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local StatePlan = require(script.Parent.ActorStatePlan)
local Domains = require(script.Parent.Parent.Parent.Actor.DomainView)
local Collections = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

export type Change = { owner: Types.DomainViewOwner, change: Types.DomainChange }
export type Event = { owner: Types.DomainViewOwner, id: string, payload: any }

export type Stage = {
	domains: { [string]: Types.DomainViewOwner },
	changes: { Change },
	events: { Event },
}

export type Plan = {
	Baseline: ({ [string]: Types.DomainViewOwner }, { [string]: SharedTypes.ActorDomainTruth }) -> (Stage?, string?),
	Commit: (
		{ [string]: Types.DomainViewOwner },
		{ SharedTypes.ActorDomainPatch },
		{ SharedTypes.ActorEvent }
	) -> (Stage?, string?),
}

local Publication = {}

local function equal(first: any, second: any): boolean
	if first == second then
		return true
	elseif type(first) ~= "table" or type(second) ~= "table" then
		return false
	end

	for key: any, value: any in next, first do
		if not equal(value, rawget(second, key)) then
			return false
		end
	end

	for key: any in next, second do
		if rawget(first, key) == nil then
			return false
		end
	end

	return true
end

-- Values have already passed the compiled semantic-event codec's validation.
local function ownPayload(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local owned: { [any]: any } = {}

	for key: any, item: any in next, value do
		owned[key] = ownPayload(item)
	end

	return table.freeze(owned)
end

local function change(owner: Types.DomainViewOwner, current: any, source: Types.DomainChangeSource): Change?
	local previous: any = owner.view:GetState()

	if equal(previous, current) then
		return nil
	end

	local record: Types.DomainChange = { previous = previous, current = current, source = source }

	return { owner = owner, change = table.freeze(record) }
end

local function orderChanges(changes: { Change }): ()
	table.sort(changes, function(first: Change, second: Change): boolean
		return first.owner.view:GetId() < second.owner.view:GetId()
	end)
end

function Publication.Compile(protocol: SharedTypes.ClientProtocol, schemas: SharedTypes.ActorSchemaCatalog): Plan
	local states: { [string]: StatePlan.Plan } = {}
	local eventIds: { [string]: { string } } = {}

	for id: string, definition: SharedTypes.ClientDomain in protocol.domainsById do
		assert(schemas[id] ~= nil, "ActorSchemaMissing")
		states[id] = StatePlan.Compile(schemas[id])

		local ids: { string } = {}

		for eventId: string in definition.eventsById do
			table.insert(ids, eventId)
		end

		table.sort(ids)
		eventIds[id] = ids
	end

	return {
		Baseline = function(
			current: { [string]: Types.DomainViewOwner },
			truth: { [string]: SharedTypes.ActorDomainTruth }
		): (Stage?, string?)
			local snapshots: { [string]: StatePlan.Result } = {}

			for id: string, domain: SharedTypes.ActorDomainTruth in truth do
				local plan: StatePlan.Plan? = states[id]

				if plan == nil or type(domain) ~= "table" then
					return nil, "InvalidActorState"
				end

				local snapshot: StatePlan.Result?, reason: string? = plan.Snapshot(domain.value)

				if snapshot == nil then
					return nil, reason
				end

				snapshots[id] = snapshot
			end

			-- Allocate owners only after every domain has passed admission.
			local stage: Stage = { domains = {}, changes = {}, events = {} }

			for id: string, snapshot: StatePlan.Result in snapshots do
				local owner: Types.DomainViewOwner? = current[id]

				if owner == nil then
					owner = Domains.new(id, snapshot.value, eventIds[id])
					assert(owner ~= nil, "DomainViewConstructionFailed")
				else
					local changed: Change? = change(owner, snapshot.value, "Baseline")

					if changed ~= nil then
						table.insert(stage.changes, changed)
					end
				end

				stage.domains[id] = owner
			end

			orderChanges(stage.changes)

			return stage, nil
		end,
		Commit = function(
			current: { [string]: Types.DomainViewOwner },
			patches: { SharedTypes.ActorDomainPatch },
			events: { SharedTypes.ActorEvent }
		): (Stage?, string?)
			if Collections.GetArrayLength(patches) == nil or Collections.GetArrayLength(events) == nil then
				return nil, "InvalidActorPatch"
			end

			local stage: Stage = { domains = current, changes = {}, events = {} }
			local touched: { [string]: boolean } = {}

			for _, patch: SharedTypes.ActorDomainPatch in patches do
				local owner: Types.DomainViewOwner? = current[patch.domainId]
				local plan: StatePlan.Plan? = states[patch.domainId]

				if owner == nil or plan == nil or touched[patch.domainId] then
					return nil, "InvalidActorPatch"
				end

				touched[patch.domainId] = true
				local result: StatePlan.Result?, reason: string? = plan.Apply(owner.view:GetState(), patch.patch)

				if result == nil then
					return nil, reason
				end

				-- Apply already preserves identity for unchanged paths; avoid a deep
				-- equality walk of unrelated subtrees on this hot path.
				if result.value ~= owner.view:GetState() then
					local record: Types.DomainChange =
						{ previous = owner.view:GetState(), current = result.value, source = "Commit" }

					table.insert(stage.changes, { owner = owner, change = table.freeze(record) })
				end
			end

			for _, event: SharedTypes.ActorEvent in events do
				local owner: Types.DomainViewOwner? = current[event.domainId]
				local domain: SharedTypes.ClientDomain? = protocol.domainsById[event.domainId]

				local declared: SharedTypes.ClientEvent? = if domain ~= nil
					then domain.eventsById[event.eventId]
					else nil

				if owner == nil or declared == nil or declared.codec.Measure(event.payload) == nil then
					return nil, "InvalidActorEvent"
				end

				table.insert(stage.events, { owner = owner, id = event.eventId, payload = ownPayload(event.payload) })
			end

			orderChanges(stage.changes)

			return stage, nil
		end,
	}
end

return Publication
