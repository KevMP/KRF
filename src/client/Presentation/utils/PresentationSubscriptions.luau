--!strict
local Types = require(script.Parent.Parent.types)
local Sources = require(script.Parent.PresentationSources)
local Scope = require(script.Parent.PresentationSubscriptionScope)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

local MAX_SUBSCRIPTIONS: number = 64

local Subscriptions = {}

function Subscriptions.New(
	definitionId: string,
	entry: Types.PresentationEntryEvent,
	host: Types.PresentationSubscriptionHost,
	environment: Types.PresentationSubscriptionEnvironment
): (Types.PresentationOn, () -> ())
	local connections: { [() -> ()]: boolean } = {}
	local count: number = 0

	local function misuse(reason: string): never
		error(("[Presentation] id=%s On: %s"):format(definitionId, reason), 3)
	end

	-- One validated dispatcher implements the public family-specific overloads.
	-- Only this boundary erases callback parameters; exported callers keep their
	-- descriptor-specific observation type, verified by the typecheck fixtures.
	local function on(_self: Types.PresentationContext, descriptor: any, ...: any): SignalTypes.Connection
		if not host.IsActive() then
			return { Disconnect = function(): () end }
		end

		local scope: Scope.Scope, callback =
			Scope.Resolve(definitionId, entry, host.GetActionAssociation(), environment.IsEligible, descriptor, ...)

		local actor: ActorTypes.ActorView? = scope.actor

		if count >= MAX_SUBSCRIPTIONS then
			misuse("SubscriptionLimit: at most 64 active subscriptions per instance")
		end

		local connected: boolean = true
		local source: SignalTypes.Connection? = nil
		local untrack: (() -> ())? = nil

		-- Automatic ownership keeps this private function, never a public handle's
		-- writable Disconnect field. Invalidation must run only framework code.
		local function disconnect(): ()
			if not connected then
				return
			end

			connected = false
			connections[disconnect] = nil
			count -= 1
			callback = nil

			if source ~= nil then
				source:Disconnect()
				source = nil
			end

			if untrack ~= nil then
				local release: () -> () = untrack
				untrack = nil
				release()
			end
		end

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

		connections[disconnect] = true
		count += 1

		source = Sources.Connect(
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

		if actor ~= nil then
			untrack = environment.TrackActor(actor, disconnect)
		end

		return { Disconnect = disconnect }
	end

	local function disconnectAll(): ()
		for disconnect: () -> () in connections do
			disconnect()
		end
	end

	return on :: Types.PresentationOn, disconnectAll
end

return table.freeze(Subscriptions)
