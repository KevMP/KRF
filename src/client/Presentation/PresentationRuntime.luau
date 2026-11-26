--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local Actors: ActorTypes.ActorViewRegistryOwner = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Sources = require(script.Parent.utils.PresentationSources)
local Instances = require(script.Parent.utils.PresentationInstance)

type InstanceSet = { [Types.PresentationContext]: boolean }
type ActorEntries = { instances: InstanceSet, connections: { SignalTypes.Connection } }

local MAX_ACTIVE_INSTANCES: number = 256
local PresentationRuntime = {}
local installed: boolean = false

local function retire(instances: InstanceSet): ()
	for context: Types.PresentationContext in instances do
		context:Finish()
	end
end

function PresentationRuntime.Install(catalog: Types.PresentationCatalog): ((() -> ())?, string?)
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
	local hints: { SignalTypes.Connection } = {}
	local observed: { [ActorTypes.ActorView]: { [() -> ()]: boolean } } = {}

	local function isEligible(actor: ActorTypes.ActorView): boolean
		return Actors.IsCurrent(actor) and not Actors.IsInvalidating(actor) and actor:IsAvailable()
	end

	local environment: Types.PresentationSubscriptionEnvironment = {
		IsEligible = function(actor: ActorTypes.ActorView): boolean
			return active and isEligible(actor)
		end,
		TrackActor = function(actor: ActorTypes.ActorView, disconnect: () -> ()): () -> ()
			local listeners: { [() -> ()]: boolean } = observed[actor] or {}

			observed[actor] = listeners
			listeners[disconnect] = true

			return function(): ()
				listeners[disconnect] = nil

				if next(listeners) == nil then
					observed[actor] = nil
				end
			end
		end,
	}

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
		local definitions: { Types.PresentationDefinition }? = catalog[descriptor][id]

		if definitions == nil then
			return
		end

		local instances: InstanceSet = actorless
		local actor: ActorTypes.ActorView? = entry.actor

		if actor ~= nil then
			local entries: ActorEntries? = actors[actor]

			if entries == nil or not isEligible(actor) then
				return
			end

			instances = entries.instances
		end

		for _, definition in definitions do
			if count >= MAX_ACTIVE_INSTANCES then
				Instances.Report(definition.id, entry, "ActiveInstanceLimit")
			else
				local context: Types.PresentationContext

				context = Instances.New(definition, entry, environment, function()
					instances[context] = nil
					count -= 1
				end)

				instances[context] = true
				count += 1
			end
		end
	end

	local function attach(actor: ActorTypes.ActorView): ()
		if active and actors[actor] == nil and isEligible(actor) then
			local entries: ActorEntries = { instances = {}, connections = {} }

			actors[actor] = entries

			for descriptor: Types.PresentationEventDescriptor in catalog do
				if descriptor.source ~= "Hint" then
					table.insert(
						entries.connections,
						Sources.Connect(descriptor, actor, function(id, entry)
							deliver(descriptor, id, entry)
						end)
					)
				end
			end
		end
	end

	local function detach(actor: ActorTypes.ActorView): ()
		local listeners: { [() -> ()]: boolean }? = observed[actor]

		if listeners ~= nil then
			for disconnect: () -> () in listeners do
				disconnect()
			end
		end

		local entries: ActorEntries? = actors[actor]

		if entries ~= nil then
			actors[actor] = nil

			for _, connection in entries.connections do
				connection:Disconnect()
			end

			retire(entries.instances)
		end
	end

	local function shutdown(): ()
		if not active then
			return
		end

		active = false

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

	if next(catalog) == nil then
		return shutdown, nil
	end

	local success: boolean = pcall(function()
		-- Install framework listeners before public Added callbacks can trigger a
		-- live event. Existing views use the same identity-indexed attach path.
		stopAdded = Actors.ObserveInstallation(attach)
		stopInvalidation = Actors.ObserveInvalidation(detach)

		for _, actor: ActorTypes.ActorView in Actors.GetAllActorViews() do
			attach(actor)
		end

		for descriptor: Types.PresentationEventDescriptor in catalog do
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
