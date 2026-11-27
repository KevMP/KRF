--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local Actors: ActorTypes.ActorViewRegistryOwner = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Sources = require(script.Parent.utils.PresentationSources)
local StateSources = require(script.Parent.utils.PresentationStateSources)
local StateEntries = require(script.Parent.utils.PresentationStateEntries)
local Instances = require(script.Parent.utils.PresentationInstance)
local Prediction = require(script.Parent.utils.PresentationPrediction)

type InstanceSet = { [Types.PresentationContext]: boolean }
type ListenerSet = { [() -> ()]: boolean }

type ActorEntries = {
	instances: InstanceSet,
	connections: { SignalTypes.Connection },
	states: StateEntries.StateEntries?,
}

local MAX_ACTIVE_INSTANCES: number = 256
local PresentationRuntime = {}
local installed: boolean = false

local function retire(instances: InstanceSet): ()
	for context: Types.PresentationContext in instances do
		context:Finish()
	end
end

local function track(
	index: { [ActorTypes.ActorView]: ListenerSet },
	actor: ActorTypes.ActorView,
	listener: () -> ()
): () -> ()
	local listeners: ListenerSet = index[actor] or {}

	index[actor] = listeners
	listeners[listener] = true

	return function(): ()
		listeners[listener] = nil

		if next(listeners) == nil and index[actor] == listeners then
			index[actor] = nil
		end
	end
end

local function delay(seconds: number, callback: () -> ()): () -> ()
	local thread: thread = task.delay(seconds, callback)

	return function(): ()
		pcall(task.cancel, thread)
	end
end

function PresentationRuntime.Install(
	catalog: Types.PresentationCatalog,
	readiness: NetworkingTypes.ActorViewStateReadinessSource?,
	prediction: Types.PresentationPredictionPort?
): ((() -> ())?, string?)
	if installed then
		return nil, "PresentationAlreadyInstalled"
	end

	installed = true
	local active: boolean = true
	local count: number = 0
	local actorless: InstanceSet = {}
	local actors: { [ActorTypes.ActorView]: ActorEntries } = {}
	local stopAdded: (() -> ())? = nil
	local stopInvalidation: (() -> ())? = nil
	local stopReadiness: (() -> ())? = nil
	local stopRequests: (() -> ())? = nil
	local stopPayloads: (() -> ())? = nil
	local predictor: Prediction.Prediction? = nil
	local hints: { SignalTypes.Connection } = {}
	local observed: { [ActorTypes.ActorView]: ListenerSet } = {}
	local readinessListeners: { [ActorTypes.ActorView]: ListenerSet } = {}

	local function isEligible(actor: ActorTypes.ActorView): boolean
		return Actors.IsCurrent(actor) and not Actors.IsInvalidating(actor) and actor:IsAvailable()
	end

	local function isStateReady(actor: ActorTypes.ActorView): boolean
		return active and readiness ~= nil and isEligible(actor) and readiness:IsStateReady(actor)
	end

	local environment: Types.PresentationSubscriptionEnvironment = {
		IsEligible = function(actor: ActorTypes.ActorView): boolean
			return active and isEligible(actor)
		end,
		TrackActor = function(actor: ActorTypes.ActorView, disconnect: () -> ()): () -> ()
			return track(observed, actor, disconnect)
		end,
		IsStateReady = isStateReady,
		ObserveReadiness = function(actor: ActorTypes.ActorView, listener: () -> ()): () -> ()
			return track(readinessListeners, actor, listener)
		end,
	}

	local function start(
		instances: InstanceSet,
		definition: Types.PresentationDefinition,
		entry: Types.PresentationEntry,
		revalidate: (() -> boolean)?,
		link: Types.PresentationPredictionLink?,
		retired: (() -> ())?
	): Types.PresentationContext?
		if count >= MAX_ACTIVE_INSTANCES then
			Instances.Report(definition.id, entry, "ActiveInstanceLimit")

			return nil
		end

		local context: Types.PresentationContext

		context = Instances.New(definition, entry, environment, function()
			instances[context] = nil
			count -= 1

			if retired ~= nil then
				retired()
			end
		end, revalidate, link)

		instances[context] = true
		count += 1

		return context
	end

	local function deliver(
		descriptor: Types.PresentationEventDescriptor,
		id: string,
		entry: Types.PresentationEntryEvent
	): ()
		if not active then
			return
		end

		if entry.source == "Resource" and entry.change.source ~= "Commit" then
			return
		end

		-- Source adapters only connect and deliver configured descriptors.
		local definitions: { Types.PresentationDefinition }? = catalog.events[descriptor][id]

		if definitions == nil then
			return
		end

		local instances: InstanceSet = actorless
		local actor: ActorTypes.ActorView? = entry.actor
		local entries: ActorEntries? = nil

		if actor ~= nil then
			entries = actors[actor]

			if entries == nil or not isEligible(actor) then
				return
			end

			instances = (entries :: ActorEntries).instances
		end

		local routed: { Types.PresentationDefinition } = {}

		for _, definition in definitions do
			if predictor ~= nil and definition.predict == true then
				table.insert(routed, definition)
			else
				start(instances, definition, entry)
			end
		end

		if predictor == nil or #routed == 0 then
			return
		end

		local function release(definition: Types.PresentationDefinition): ()
			if not active then
				return
			end

			local target: ActorTypes.ActorView? = actor

			if target == nil then
				start(actorless, definition, entry)

				return
			end

			local current: ActorEntries? = actors[target]

			if current ~= nil and current == entries and isEligible(target) then
				start(current.instances, definition, entry)
			end
		end

		if entry.source == "Action" then
			predictor.Route(entry, routed, release)
		elseif entry.source == "Hint" then
			predictor.RouteHint(entry, routed, release)
		end
	end

	local function attach(actor: ActorTypes.ActorView): ()
		if not active or actors[actor] ~= nil or not isEligible(actor) then
			return
		end

		local entries: ActorEntries = { instances = {}, connections = {}, states = nil }

		actors[actor] = entries

		for descriptor: Types.PresentationEventDescriptor in catalog.events do
			if descriptor.source ~= "Hint" then
				table.insert(
					entries.connections,
					Sources.Connect(descriptor, actor, function(id, entry)
						deliver(descriptor, id, entry)
					end)
				)
			end
		end

		if next(catalog.states) ~= nil then
			local states: StateEntries.StateEntries = StateEntries.new(actor, catalog.states, {
				IsReady = function(): boolean
					return actors[actor] == entries and isStateReady(actor)
				end,
				Start = function(
					definition: Types.PresentationDefinition,
					entry: Types.PresentationStateEntry,
					revalidate: () -> boolean
				): Types.PresentationContext?
					return start(entries.instances, definition, entry, revalidate)
				end,
			})

			entries.states = states

			for descriptor: Types.PresentationStateEntryDescriptor in catalog.states do
				for _, connection: SignalTypes.Connection in
					StateSources.Connect(descriptor.source, actor, states.Schedule)
				do
					table.insert(entries.connections, connection)
				end
			end

			states.Schedule()
		end
	end

	local function detach(actor: ActorTypes.ActorView): ()
		if predictor ~= nil then
			predictor.RetireActor(actor)
		end

		local listeners: ListenerSet? = observed[actor]

		if listeners ~= nil then
			for disconnect: () -> () in listeners do
				disconnect()
			end
		end

		readinessListeners[actor] = nil

		local entries: ActorEntries? = actors[actor]

		if entries ~= nil then
			actors[actor] = nil

			for _, connection in entries.connections do
				connection:Disconnect()
			end

			if entries.states ~= nil then
				entries.states.Destroy()
			end

			retire(entries.instances)
		end
	end

	local function onReadiness(actor: ActorTypes.ActorView, state: NetworkingTypes.ActorViewStateReadiness): ()
		local entries: ActorEntries? = actors[actor]

		if not active or entries == nil or state ~= "Ready" then
			return
		end

		if entries.states ~= nil then
			entries.states.Schedule()
		end

		if predictor ~= nil then
			predictor.ObserveBaseline(actor)
		end

		local listeners: ListenerSet? = readinessListeners[actor]

		if listeners ~= nil then
			for listener: () -> () in table.clone(listeners) do
				listener()
			end
		end
	end

	local function shutdown(): ()
		if not active then
			return
		end

		active = false

		if stopReadiness ~= nil then
			stopReadiness()
		end

		if stopRequests ~= nil then
			stopRequests()
		end

		if stopPayloads ~= nil then
			stopPayloads()
		end

		if predictor ~= nil then
			predictor.Destroy()
		end

		if stopAdded ~= nil then
			stopAdded()
		end

		if stopInvalidation ~= nil then
			stopInvalidation()
		end

		for _, connection in hints do
			connection:Disconnect()
		end

		for actor: ActorTypes.ActorView in actors do
			detach(actor)
		end

		retire(actorless)
		installed = false
	end

	if next(catalog.events) == nil and next(catalog.states) == nil then
		return shutdown, nil
	end

	local success: boolean = pcall(function()
		if readiness ~= nil then
			stopReadiness = readiness:ObserveStateReadiness(onReadiness)
		end

		if prediction ~= nil and next(catalog.predictions.definitions) ~= nil then
			local coordinator: Prediction.Prediction = Prediction.new(catalog.predictions, {
				IsEligible = function(actor: ActorTypes.ActorView): boolean
					return active and isEligible(actor)
				end,
				IsStateReady = isStateReady,
				Start = function(actor, definition, entry, link, revalidate, retired): Types.PresentationContext?
					if not active then
						return nil
					elseif actor == nil then
						return start(actorless, definition, entry, revalidate, link, retired)
					end

					local entries: ActorEntries? = actors[actor]

					if entries == nil or not isEligible(actor) then
						return nil
					end

					return start(entries.instances, definition, entry, revalidate, link, retired)
				end,
				Report = function(actionId: string, actorId: string, reason: string): ()
					warn(("[Presentation] action=%s actor=%s reason=%s"):format(actionId, actorId, reason))
				end,
				ReportHint = function(hintId: string, reason: string): ()
					warn(("[Presentation] hint=%s reason=%s"):format(hintId, reason))
				end,
			}, {
				Delay = prediction.Delay or delay,
				Measure = prediction.Measure or os.clock,
			})

			predictor = coordinator
			stopRequests = prediction.ObserveActionRequest(coordinator.Observe)
			stopPayloads = prediction.ObserveStartPayloads(coordinator.AttachPayload)
		end

		-- Install framework listeners before public Added callbacks can trigger a
		-- live event. Existing views use the same identity-indexed attach path.
		stopAdded = Actors.ObserveInstallation(attach)
		stopInvalidation = Actors.ObserveInvalidation(detach)

		for _, actor: ActorTypes.ActorView in Actors.GetAllActorViews() do
			attach(actor)
		end

		for descriptor: Types.PresentationEventDescriptor in catalog.events do
			if descriptor.source == "Hint" then
				table.insert(
					hints,
					Sources.Connect(descriptor, nil, function(id, entry)
						deliver(descriptor, id, entry)
					end)
				)
			end
		end
	end)

	if not success then
		shutdown()

		return nil, "PresentationInstallationFailed"
	end

	return shutdown, nil
end

return table.freeze(PresentationRuntime)
