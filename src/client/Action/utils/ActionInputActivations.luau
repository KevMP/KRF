--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local Identity = require(script.Parent.ActionRouteIdentity)

export type IdentitySnapshot = {
	read actor: ActorTypes.ActorView,
	read actionId: string,
	read key: Types.RouteKey,
	read sourceId: string,
	read routeVersion: number,
	read generation: number,
	read timestamp: number,
	read hold: InputTypes.RecognitionHoldOwner?,
}

export type Record = {
	identity: IdentitySnapshot,
	policy: Types.CompiledActionInputPolicy,
	admission: RequestTypes.ActionRequestAdmission?,
	live: boolean,
	starting: boolean,
	busy: boolean,
	delivery: "None" | "Stop" | "Interrupt" | "Complete",
	intent: "Stop" | "Interrupt" | "Keep"?,
	pendingDecision: Types.ActionInputDecisionKind?,
	reason: string?,
}

type Records = { [Record]: boolean }

export type Owner = {
	Add: (Types.ActionRouteSelection, Types.CompiledActionInputPolicy) -> Record?,
	Bind: (Record, RequestTypes.ActionRequestAdmission) -> (),
	Remove: (Record) -> (),
	ConsumeEpoch: (Record) -> (),
	FindToggle: (Types.ActionRouteSelection) -> Record?,
	ByRequest: (number) -> Record?,
	ByEpoch: (InputTypes.PrimitiveOccurrence) -> { Record },
	ByRoute: (ActorTypes.ActorView, Types.RouteKey) -> { Record },
	ByActor: (ActorTypes.ActorView?) -> { Record },
	Revision: () -> number,
	HasActive: () -> boolean,
	Touch: () -> (),
	Destroy: () -> (),
}

local Activations = {}

function Activations.new(): Owner
	local records: Records = {}
	local requests: { [number]: Record } = {}
	local routes: { [ActorTypes.ActorView]: { [string]: Records } } = {}
	local epochs: { [string]: { [number]: Records } } = {}
	local identities: { [ActorTypes.ActorView]: { [string]: Record } } = {}
	local count: number = 0
	local revision: number = 0

	local function activationKey(
		key: Types.RouteKey,
		actionId: string,
		sourceId: string,
		version: number,
		hold: InputTypes.RecognitionHoldOwner?
	): string
		return Identity.Canonical(key)
			.. ":"
			.. #sourceId
			.. ":"
			.. sourceId
			.. ":"
			.. version
			.. ":"
			.. #actionId
			.. ":"
			.. actionId
			.. ":"
			.. (if hold ~= nil then hold.inputGeneration .. ":" .. hold.pressEpochId else "Toggle")
	end

	local function snapshot(set: Records?): { Record }
		local result: { Record } = {}

		for record: Record in set or {} do
			table.insert(result, record)
		end

		return result
	end

	local function consume(record: Record): ()
		local hold: InputTypes.RecognitionHoldOwner? = record.identity.hold

		if hold ~= nil then
			local input = epochs[hold.inputId]
			local epoch: Records? = if input ~= nil then input[hold.pressEpochId] else nil

			if epoch ~= nil then
				epoch[record] = nil

				if next(epoch) == nil then
					input[hold.pressEpochId] = nil
				end

				if next(input) == nil then
					epochs[hold.inputId] = nil
				end
			end
		end
	end

	local function remove(record: Record): ()
		if not record.live then
			return
		end

		record.live = false
		records[record] = nil
		count -= 1
		revision += 1
		consume(record)
		local actor: ActorTypes.ActorView = record.identity.actor
		local key: string = Identity.Canonical(record.identity.key)

		local actorRoutes = routes[actor]
		actorRoutes[key][record] = nil

		if next(actorRoutes[key]) == nil then
			actorRoutes[key] = nil
		end

		if next(actorRoutes) == nil then
			routes[actor] = nil
		end

		if record.admission ~= nil then
			requests[record.admission.requestId] = nil
		end

		local actorIdentities = identities[actor]

		actorIdentities[activationKey(
			record.identity.key,
			record.identity.actionId,
			record.identity.sourceId,
			record.identity.routeVersion,
			if record.policy.activation == "Toggle" then nil else record.identity.hold
		)] =
			nil

		if next(actorIdentities) == nil then
			identities[actor] = nil
		end
	end

	return {
		Add = function(selection, policy): Record?
			if count >= 64 then
				return nil
			end

			local identityKey: string = activationKey(
				selection.key,
				selection.actionId,
				selection.sourceId,
				selection.routeVersion,
				if policy.activation == "Toggle" then nil else selection.holdOwner
			)

			local actorIdentities = identities[selection.actor] or {}

			if actorIdentities[identityKey] ~= nil then
				return nil
			end

			local record: Record = {
				identity = table.freeze({
					actor = selection.actor,
					actionId = selection.actionId,
					key = selection.key,
					sourceId = selection.sourceId,
					routeVersion = selection.routeVersion,
					generation = selection.selectionGeneration,
					timestamp = selection.envelope.timestamp,
					hold = selection.holdOwner,
				}),
				policy = policy,
				live = true,
				starting = true,
				busy = false,
				delivery = "None",
			}

			records[record] = true
			count += 1
			revision += 1
			local actor: ActorTypes.ActorView = selection.actor
			local key: string = Identity.Canonical(selection.key)
			local actorRoutes = routes[actor] or {}

			routes[actor] = actorRoutes

			local bucket: Records = actorRoutes[key] or {}

			actorRoutes[key] = bucket
			bucket[record] = true

			identities[actor] = actorIdentities
			actorIdentities[identityKey] = record

			if policy.activation ~= "Toggle" and selection.holdOwner ~= nil then
				local hold = selection.holdOwner

				epochs[hold.inputId] = epochs[hold.inputId] or {}
				epochs[hold.inputId][hold.pressEpochId] = epochs[hold.inputId][hold.pressEpochId] or {}
				epochs[hold.inputId][hold.pressEpochId][record] = true
			end

			return record
		end,
		Bind = function(record, admission): ()
			record.admission = admission

			if record.live then
				requests[admission.requestId] = record
				revision += 1
			end
		end,
		Remove = remove,
		ConsumeEpoch = consume,
		FindToggle = function(selection): Record?
			local actor = identities[selection.actor]

			return if actor ~= nil
				then actor[activationKey(
					selection.key,
					selection.actionId,
					selection.sourceId,
					selection.routeVersion,
					nil
				)]
				else nil
		end,
		ByRequest = function(requestId): Record?
			return requests[requestId]
		end,
		ByEpoch = function(occurrence): { Record }
			local input = epochs[occurrence.event.inputId]

			local candidates = snapshot(
				if input ~= nil and occurrence.pressEpochId ~= nil then input[occurrence.pressEpochId] else nil
			)

			local result: { Record } = {}

			for _, record in candidates do
				if assert(record.identity.hold, "Expected indexed hold").inputGeneration == occurrence.generation then
					table.insert(result, record)
				end
			end

			return result
		end,
		ByRoute = function(actor, key): { Record }
			return snapshot(if routes[actor] ~= nil then routes[actor][Identity.Canonical(key)] else nil)
		end,
		ByActor = function(actor): { Record }
			local result: { Record } = {}

			for _, bucket in if actor ~= nil then routes[actor] or {} else {} do
				for _, record in snapshot(bucket) do
					table.insert(result, record)
				end
			end

			return result
		end,
		Revision = function(): number
			return revision
		end,
		HasActive = function(): boolean
			return count > 0
		end,
		Touch = function(): ()
			revision += 1
		end,
		Destroy = function(): ()
			for _, record in snapshot(records) do
				remove(record)
			end
		end,
	}
end

return Activations
