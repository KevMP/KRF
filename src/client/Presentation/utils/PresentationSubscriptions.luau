--!strict
local Types = require(script.Parent.Parent.types)
local Sources = require(script.Parent.PresentationSources)
local Scope = require(script.Parent.PresentationSubscriptionScope)
local Watch = require(script.Parent.PresentationWatch)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

local MAX_SUBSCRIPTIONS: number = 64

local Subscriptions = {}

local function inert(): SignalTypes.Connection
	return { Disconnect = function(): () end }
end

function Subscriptions.New(
	definitionId: string,
	entry: Types.PresentationEntry,
	host: Types.PresentationSubscriptionHost,
	environment: Types.PresentationSubscriptionEnvironment
): (Types.PresentationOn, Types.PresentationWatch, () -> ())
	local connections: { [() -> ()]: boolean } = {}
	local count: number = 0

	local function admit(method: string): ()
		if count >= MAX_SUBSCRIPTIONS then
			error(
				("[Presentation] id=%s %s: SubscriptionLimit: at most 64 active subscriptions per instance"):format(
					definitionId,
					method
				),
				3
			)
		end
	end

	local function own(
		actor: ActorTypes.ActorView?,
		sources: { SignalTypes.Connection },
		release: () -> ()
	): SignalTypes.Connection
		local connected: boolean = true
		local untrack: (() -> ())? = nil

		local function disconnect(): ()
			if not connected then
				return
			end

			connected = false
			connections[disconnect] = nil
			count -= 1
			release()

			for _, source: SignalTypes.Connection in sources do
				source:Disconnect()
			end

			table.clear(sources)

			if untrack ~= nil then
				local stop: () -> () = untrack
				untrack = nil
				stop()
			end
		end

		connections[disconnect] = true
		count += 1

		if actor ~= nil then
			untrack = environment.TrackActor(actor, disconnect)
		end

		return { Disconnect = disconnect }
	end

	local function on(_self: Types.PresentationContext, descriptor: any, ...: any): SignalTypes.Connection
		if not host.IsActive() then
			return inert()
		end

		local scope: Scope.Scope, callback =
			Scope.Resolve(definitionId, entry, host.GetActionAssociation(), environment.IsEligible, descriptor, ...)

		local actor: ActorTypes.ActorView? = scope.actor
		admit("On")
		local connected: boolean = true

		local function matches(sourceId: string, observation: Types.PresentationEntryEvent): boolean
			if not connected or not host.IsActive() then
				return false
			elseif actor ~= nil and not environment.IsEligible(actor) then
				return false
			elseif observation.actor ~= nil and not environment.IsEligible(observation.actor) then
				return false
			elseif not scope.anyHint and observation.actor ~= actor then
				return false
			end

			if scope.activation then
				local association: Types.PresentationActionAssociation? = host.GetActionAssociation()

				return association ~= nil
					and observation.source == "Action"
					and observation.actor == association.actor
					and sourceId == association.actionId
					and association.sequenceId ~= nil
					and observation.action.sequenceId == association.sequenceId
			end

			return sourceId == scope.id
		end

		local source: SignalTypes.Connection = Sources.Connect(
			scope.descriptor,
			actor,
			function(sourceId: string, observation: Types.PresentationEntryEvent)
				if not matches(sourceId, observation) then
					return
				end

				task.defer(function()
					if not matches(sourceId, observation) then
						return
					end

					local success: boolean, failure: any = pcall(callback, observation)

					if not success then
						host.Fail(
							observation,
							"CallbackFailed:" .. (if type(failure) == "string" then failure else "NonStringError")
						)
					end
				end)
			end
		)

		return own(actor, { source }, function(): ()
			connected = false
			callback = nil
		end)
	end

	local function watch(_self: Types.PresentationContext, descriptor: any, ...: any): SignalTypes.Connection
		if not host.IsActive() then
			return inert()
		end

		local plan: Watch.WatchPlan, callback: (any) -> () = Watch.Resolve(
			definitionId,
			entry,
			host.GetActionAssociation(),
			host.GetPrediction(),
			environment.IsEligible,
			descriptor,
			...
		)

		admit("Watch")

		local sources: { SignalTypes.Connection }, release: () -> () =
			Watch.Start(plan, callback, entry, host, environment)

		return own(plan.actor, sources, release)
	end

	local function disconnectAll(): ()
		for disconnect: () -> () in connections do
			disconnect()
		end
	end

	return on :: Types.PresentationOn, watch :: Types.PresentationWatch, disconnectAll
end

return table.freeze(Subscriptions)
