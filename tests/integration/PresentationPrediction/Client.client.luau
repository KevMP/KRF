--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local ClientTypes = require(KRF.client.types)
local ActionTypes = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Presentation.types)
local Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local FireballRequirements = require(ReplicatedStorage.PredictionShared.FireballRequirements)
local schemas = require(ReplicatedStorage.PredictionShared.Schemas)
local report: RemoteEvent = ReplicatedStorage:WaitForChild("PredictionReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("PredictionProbe") :: RemoteFunction

local ROUND_TRIPS_MS: { number } = { 0, 50, 100, 200, 300 }
local FIREBALL_SAMPLES: number = 12
local WARD_SAMPLES: number = 4

type Cast = {
	actionId: string,
	started: number,
	key: string?,
	predicted: number?,
	authoritative: number?,
	authoritativeSequenceId: number?,
	accepted: number?,
	sequenceId: number?,
	rejected: number?,
	ended: number?,
	parameters: any?,
}

type Queued = { due: number, deliver: () -> () }
type Summary = { median: number, p90: number, min: number, max: number, samples: number }

local oneWaySeconds: number = 0
local current: Cast? = nil
local mine: ActorTypes.ActorView? = nil
local predictedInstances: number = 0
local fallbacks: { [ActorTypes.ActorView]: number } = {}
local outcomes: { ActionTypes.ActionRequestOutcome } = {}

local function channel(): (() -> ()) -> ()
	local queue: { Queued } = {}

	local function drain(): ()
		while queue[1] ~= nil and queue[1].due <= os.clock() do
			local item: Queued = table.remove(queue, 1) :: Queued
			item.deliver()
		end
	end

	return function(deliver: () -> ()): ()
		if oneWaySeconds <= 0 and #queue == 0 then
			deliver()

			return
		end

		local last: Queued? = queue[#queue]
		local due: number = math.max(os.clock() + oneWaySeconds, if last ~= nil then last.due else 0)

		table.insert(queue, { due = due, deliver = deliver })
		task.delay(math.max(0, due - os.clock()), drain)
	end
end

local discover = Native.DiscoverTransport

Native.DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
	local transport: ClientTypes.ClientTransport?, reason: string? = discover(deadline)

	if transport == nil then
		return nil, reason
	end

	local real: ClientTypes.ClientTransport = transport
	local outbound: (() -> ()) -> () = channel()
	local inbound: (() -> ()) -> () = channel()

	return {
		SendReliable = function(payload: buffer): ()
			outbound(function(): ()
				real.SendReliable(payload)
			end)
		end,
		ConnectReliable = function(callback: (any, ...any) -> ()): () -> ()
			return real.ConnectReliable(function(payload: any, ...: any): ()
				local extra = table.pack(...)

				inbound(function(): ()
					callback(payload, table.unpack(extra, 1, extra.n))
				end)
			end)
		end,
		SendUnreliable = real.SendUnreliable,
		ConnectUnreliable = real.ConnectUnreliable,
	},
		nil
end

local function waitFor<T>(label: string, read: () -> T?, seconds: number?): T
	local deadline: number = os.clock() + (seconds or 8)

	while true do
		local value: T? = read()

		if value ~= nil then
			return value
		end

		assert(os.clock() < deadline, "PredictionWait:" .. label)
		RunService.Heartbeat:Wait()
	end
end

local function own(context: Types.PresentationContext): boolean
	return mine ~= nil and context.actor == mine
end

local predictedFireball: Types.PresentationDefinition = {
	id = "Fireball.Predicted",
	entry = { event = Events.Action.Started, id = "Fireball" },
	predict = true,
	create = function(context: Types.PresentationContext)
		local entry: Types.PresentationEntry = context.entry

		if entry.source ~= "ActionPrediction" then
			local actor: ActorTypes.ActorView = assert(context.actor, "Authoritative entry has an ActorView")

			fallbacks[actor] = (fallbacks[actor] or 0) + 1
			context:Finish()

			return
		end

		assert(own(context), "Prediction created for another ActorView")
		predictedInstances += 1
		local cast: Cast? = current

		if cast ~= nil and cast.predicted == nil then
			cast.predicted = os.clock()
			cast.key = entry.originalStartKey
			cast.parameters = entry.parameters
		end

		context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
			if cast == nil or cast.key ~= entry.originalStartKey then
				return
			elseif snapshot.startStatus == "Accepted" and cast.accepted == nil then
				cast.accepted = os.clock()
				cast.sequenceId = snapshot.sequenceId
			elseif snapshot.startStatus == "Rejected" and cast.rejected == nil then
				cast.rejected = os.clock()
				context:Finish()
			end
		end)

		context:Watch(States.Action.Active, function(snapshot: ActorTypes.ActionSnapshot?)
			if snapshot == nil and cast ~= nil and cast.accepted ~= nil then
				context:Finish()
			end
		end)
	end,
}

local authoritativeFireball: Types.PresentationDefinition = {
	id = "Fireball.Authoritative",
	entry = { event = Events.Action.Started, id = "Fireball" },
	create = function(context: Types.PresentationContext)
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source == "Action", "Non-predicted definition received a predicted entry")
		local cast: Cast? = current

		if not own(context) or cast == nil or cast.actionId ~= "Fireball" then
			context:Finish()

			return
		end

		cast.authoritative = os.clock()
		cast.authoritativeSequenceId = entry.action.sequenceId

		context:Watch(States.Action.Active, function(snapshot: ActorTypes.ActionSnapshot?)
			if snapshot == nil then
				cast.ended = os.clock()
				context:Finish()
			end
		end)
	end,
}

local predictedWard: Types.PresentationDefinition = {
	id = "Ward.Predicted",
	entry = { event = Events.Action.Started, id = "Ward" },
	predict = true,
	create = function(context: Types.PresentationContext)
		local entry: Types.PresentationEntry = context.entry
		assert(entry.source == "ActionPrediction", "A rejected Ward replicated an authoritative Start")
		local cast: Cast? = current

		if cast ~= nil and cast.predicted == nil then
			cast.predicted = os.clock()
			cast.key = entry.originalStartKey
		end

		context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
			if cast ~= nil and snapshot.startStatus == "Rejected" and cast.rejected == nil then
				cast.rejected = os.clock()
				context:Finish()
			end
		end)
	end,
}

local function cast(actionId: string): Cast
	local actor: ActorTypes.ActorView = assert(mine, "Expected the local caster")
	local record: Cast = { actionId = actionId, started = os.clock() }

	current = record
	assert(Runtime.RequestAction(actor, actionId, if actionId == "Fireball" then { aim = 1 } else nil))

	return record
end

local function settleFireball(record: Cast): ()
	local deadline: number = os.clock() + 8

	while record.predicted == nil or record.authoritative == nil or record.accepted == nil or record.ended == nil do
		assert(
			os.clock() < deadline,
			("PredictionWait:FireballSettled predicted=%s authoritative=%s accepted=%s ended=%s"):format(
				tostring(record.predicted ~= nil),
				tostring(record.authoritative ~= nil),
				tostring(record.accepted ~= nil),
				tostring(record.ended ~= nil)
			)
		)

		RunService.Heartbeat:Wait()
	end

	current = nil
end

local function settleWard(record: Cast): ()
	waitFor("WardSettled", function(): boolean?
		return if record.predicted ~= nil and record.rejected ~= nil then true else nil
	end)

	current = nil
end

local function summarize(values: { number }): Summary
	table.sort(values)

	local function rank(fraction: number): number
		return values[math.clamp(math.ceil(fraction * #values), 1, #values)]
	end

	local function round(value: number): number
		return math.floor(value * 10 + 0.5) / 10
	end

	return {
		median = round(rank(0.5)),
		p90 = round(rank(0.9)),
		min = round(values[1]),
		max = round(values[#values]),
		samples = #values,
	}
end

local function verify(): ()
	local actor: ActorTypes.ActorView = assert(mine, "Expected the local caster")

	local first: Cast = cast("Fireball")
	settleFireball(first)

	assert(
		(first.predicted :: number) < (first.authoritative :: number),
		"Prediction did not precede the authoritative Start"
	)

	assert(first.sequenceId == first.authoritativeSequenceId, "Adopted sequenceId differs from the replicated Start")
	assert(first.parameters ~= nil and first.parameters.aim == 1, "Predicted entry lost the original parameters")
	assert(predictedInstances == 1 and (fallbacks[actor] or 0) == 0, "Authoritative Start replayed the prediction")

	local ward: Cast = cast("Ward")
	settleWard(ward)

	assert(probe:InvokeServer("Stun"), "Expected server Stun")

	waitFor("StunReplicated", function(): boolean?
		return if actor:GetTags():HasTag("Status.Stunned") then true else nil
	end)

	local before: number = predictedInstances
	local seen: number = #outcomes
	local stunned: Cast = cast("Fireball")

	waitFor("StunnedRejected", function(): boolean?
		local outcome: ActionTypes.ActionRequestOutcome? = outcomes[seen + 1]

		return if outcome ~= nil and outcome.status == "Rejected" and outcome.actionId == "Fireball" then true else nil
	end)

	task.wait(0.1)
	assert(stunned.predicted == nil and predictedInstances == before, "A locally blocked Start was previewed")
	current = nil
	assert(probe:InvokeServer("Unstun"), "Expected server Unstun")

	waitFor("StunCleared", function(): boolean?
		return if actor:GetTags():HasTag("Status.Stunned") then nil else true
	end)

	local npc: ActorTypes.ActorView = waitFor("NPCView", function(): ActorTypes.ActorView?
		local id: unknown = ReplicatedStorage:GetAttribute("PredictionNPCId")

		return if type(id) == "string" then Registry.GetActorViewById(id) else nil
	end)

	assert(probe:InvokeServer("NPC"), "Expected NPC Fireball")

	waitFor("NPCAuthoritative", function(): boolean?
		return if (fallbacks[npc] or 0) > 0 then true else nil
	end)

	assert(predictedInstances == before, "A bystander Start created a local prediction")
end

local function measure(): { [string]: any }
	local scenarios: { [string]: any } = {}

	for _, roundTrip: number in ROUND_TRIPS_MS do
		oneWaySeconds = roundTrip / 2000
		task.wait(0.5)

		local predicted: { number } = {}
		local authoritative: { number } = {}
		local accepted: { number } = {}
		local wardPredicted: { number } = {}
		local wardRejected: { number } = {}

		for _ = 1, FIREBALL_SAMPLES do
			local record: Cast = cast("Fireball")
			settleFireball(record)
			table.insert(predicted, ((record.predicted :: number) - record.started) * 1000)
			table.insert(authoritative, ((record.authoritative :: number) - record.started) * 1000)
			table.insert(accepted, ((record.accepted :: number) - record.started) * 1000)
		end

		for _ = 1, WARD_SAMPLES do
			local record: Cast = cast("Ward")
			settleWard(record)
			table.insert(wardPredicted, ((record.predicted :: number) - record.started) * 1000)
			table.insert(wardRejected, ((record.rejected :: number) - record.started) * 1000)
		end

		local summary = {
			fireballPredicted = summarize(predicted),
			fireballAuthoritative = summarize(authoritative),
			fireballAccepted = summarize(accepted),
			wardPredicted = summarize(wardPredicted),
			wardRejected = summarize(wardRejected),
		}

		if roundTrip >= 100 then
			assert(
				summary.fireballPredicted.p90 < summary.fireballAuthoritative.median,
				"Prediction did not beat the authoritative round trip at " .. roundTrip .. " ms"
			)
		end

		scenarios["rtt" .. roundTrip] = summary
	end

	oneWaySeconds = 0

	return scenarios
end

local function run(): { [string]: any }
	local initialized: boolean, failure = Client.Init({
		actionRequestSchemas = schemas,
		actionPredictionPolicies = {
			Fireball = {
				requiredTags = FireballRequirements.requiredTags,
				blockedTags = FireballRequirements.blockedTags,
				resourceRequirements = FireballRequirements.resourceRequirements,
				costs = FireballRequirements.costs,
				canPredictStart = function(context: Types.ActionPredictionCheckContext): boolean?
					return if context.parameters ~= nil then context.parameters.aim >= 0 else nil
				end,
			},
			Ward = {},
		},
		presentations = { predictedFireball, authoritativeFireball, predictedWard },
	})

	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")

	Runtime.OnActionRequest:Connect(function(fact: ActionTypes.ActionRequestEvent): ()
		if fact.kind == "RequestOutcome" then
			table.insert(outcomes, fact)
		end
	end)

	mine = waitFor("CasterView", function(): ActorTypes.ActorView?
		local id: unknown = Players.LocalPlayer:GetAttribute("PredictionActor")
		local view: ActorTypes.ActorView? = if type(id) == "string" then Registry.GetActorViewById(id) else nil

		return if view ~= nil and view:GetTags():HasTag("Status.Grounded") then view else nil
	end)

	waitFor("ManaReplicated", function(): boolean?
		return if (assert(mine, "Expected the local caster"):GetResources():GetCurrent("Mana") or 0) > 0
			then true
			else nil
	end)

	verify()

	return measure()
end

local success: boolean, result: any = pcall(run)
report:FireServer(if success then nil else tostring(result), if success then result else nil)
