--!strict
local Types = require(script.Parent.Parent.types)
local StateSources = require(script.Parent.PresentationStateSources)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

export type WatchPlan = {
	read family: StateSources.StateFamily,
	read actor: ActorTypes.ActorView,
	read id: string?,
}

local Watch = {}

function Watch.Resolve(
	definitionId: string,
	entry: Types.PresentationEntry,
	association: Types.PresentationActionAssociation?,
	prediction: Types.PresentationPredictionLink?,
	isEligible: (ActorTypes.ActorView) -> boolean,
	descriptor: any,
	...: any
): (WatchPlan, (any) -> ())
	local function misuse(reason: string): never
		error(("[Presentation] id=%s Watch: %s"):format(definitionId, reason), 4)
	end

	if not StateSources.IsKnown(descriptor) then
		misuse("UnknownStateDescriptor: use PresentationStates constants")
	end

	local family: StateSources.StateFamily = StateSources.Family(descriptor)
	local keyed: boolean = family == "Tag" or family == "Resource"

	if select("#", ...) ~= (if keyed then 2 else 1) then
		misuse(
			if keyed
				then "InvalidArguments: expected state, id, callback"
				else "InvalidArguments: expected state, callback"
		)
	end

	local first: any, second: any = ...
	local id: any = if keyed then first else nil
	local callback: any = if keyed then second else first

	if type(callback) ~= "function" then
		misuse("CallbackInvalid: expected a function")
	elseif keyed and (type(id) ~= "string" or id == "") then
		misuse("IdInvalid: expected a nonempty source id")
	end

	local actor: ActorTypes.ActorView? = entry.actor

	if actor == nil then
		misuse("ActorMissing: Watch requires an originating ActorView")
	elseif not isEligible(actor) then
		misuse("ActorUnavailable: origin must be a current available ActorView")
	elseif
		family == "Action"
		and (association == nil or association.actor ~= actor or (association.sequenceId == nil and prediction == nil))
	then
		misuse("OriginActionMissing: Action.Active requires an originating Action activation")
	elseif family == "LocalPrediction" and prediction == nil then
		misuse("OriginPredictionMissing: Action.LocalPrediction requires a locally predicted Action entry")
	end

	return { family = family, actor = assert(actor, "Watch origin was validated"), id = id }, callback
end

function Watch.Start(
	plan: WatchPlan,
	callback: (any) -> (),
	entry: Types.PresentationEntry,
	host: Types.PresentationSubscriptionHost,
	environment: Types.PresentationSubscriptionEnvironment
): ({ SignalTypes.Connection }, () -> ())
	local actor: ActorTypes.ActorView = plan.actor
	local replicated: boolean = plan.family ~= "Actor" and plan.family ~= "LocalPrediction"
	local prediction: Types.PresentationPredictionLink? = host.GetPrediction()
	local connected: boolean = true
	local pending: boolean = false
	local delivered: boolean = false
	local last: StateSources.Signature = {}

	local function sample(): (any, StateSources.Signature)
		if plan.family == "Tag" then
			return StateSources.SampleTag(actor, plan.id :: string)
		elseif plan.family == "Resource" then
			return StateSources.SampleResource(actor, plan.id :: string)
		elseif plan.family == "Action" then
			return StateSources.SampleAction(host.GetActionAssociation())
		elseif plan.family == "LocalPrediction" then
			local snapshot: Types.LocalPredictionSnapshot, revision: number =
				assert(prediction, "LocalPrediction Watch requires a prediction link").GetSnapshot()

			return snapshot, { revision }
		end

		return StateSources.SampleModel(actor)
	end

	local function flush(): ()
		pending = false

		if not connected or not host.IsActive() or not environment.IsEligible(actor) then
			return
		elseif replicated and not environment.IsStateReady(actor) then
			return
		end

		local value: any, signature: StateSources.Signature = sample()

		if delivered and StateSources.Same(signature, last) then
			return
		end

		delivered = true
		last = signature
		local success: boolean, failure: any = pcall(callback, value)

		if not success then
			host.Fail(entry, "WatchFailed:" .. (if type(failure) == "string" then failure else "NonStringError"))
		end
	end

	local function schedule(): ()
		if connected and not pending then
			pending = true
			task.defer(flush)
		end
	end

	local sources: { SignalTypes.Connection } = StateSources.Connect(plan.family, actor, schedule)

	if prediction ~= nil and (plan.family == "Action" or plan.family == "LocalPrediction") then
		local stopPrediction: () -> () = prediction.Observe(schedule)

		table.insert(sources, {
			Disconnect = function(): ()
				stopPrediction()
			end,
		})
	end

	if replicated then
		local stopReadiness: () -> () = environment.ObserveReadiness(actor, schedule)

		table.insert(sources, {
			Disconnect = function(): ()
				stopReadiness()
			end,
		})
	end

	schedule()

	return sources, function(): ()
		connected = false
	end
end

return table.freeze(Watch)
