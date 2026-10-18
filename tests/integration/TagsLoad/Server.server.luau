--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Scenario = require(ReplicatedStorage.TagsLoadScenario)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("TagsLoadControl") :: RemoteEvent

Players.CharacterAutoLoads = false

local subjects: { ActorTypes.Actor } = {}
local models: { Model } = {}
local ready: { [Player]: boolean } = {}
local replies: { [Player]: any } = {}
local waveReplies: { [number]: { [Player]: any } } = {}
local starts: { [number]: { number } } = {}
local waveStarts: { [number]: number } = {}
local waveAckMs: { number } = {}
local observedMs: { number } = {}
local cpuUs: { number } = {}
local framesMs: { number } = {}
local cases: { any } = {}
local phase: string = "Ready"
local measuring: boolean = false
local finished: boolean = false
local commits: number = 0
local ticks: number = 0
local expectedRounds: number = 0
local lastGeneration: number = 0
local disconnectPublication: (() -> ())? = nil
local sentTraffic: { [Player]: { bytes: number, packets: number } } = {}
local originalSendReliable = Networking.SendReliable

-- Observe successful ordinary Actor stream sends; delegate the actual transport unchanged.
Networking.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
	local success: boolean, reason: string? = originalSendReliable(player, payload)

	if success and measuring and buffer.len(payload) > 0 and buffer.readu8(payload, 0) == Constants.PACKET_KIND then
		local traffic = sentTraffic[player] or { bytes = 0, packets = 0 }
		traffic.bytes += buffer.len(payload)
		traffic.packets += 1
		sentTraffic[player] = traffic
	end

	return success, reason
end

local heartbeat: RBXScriptConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
	if measuring then
		table.insert(framesMs, deltaTime * 1000)
	end
end)

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	heartbeat:Disconnect()

	local cleaned: boolean, cleanupReason: any = pcall(function()
		if disconnectPublication ~= nil then
			disconnectPublication()
		end

		for _, actor: ActorTypes.Actor in subjects do
			Actors.UnregisterActor(actor)
		end

		Networking.Destroy()

		for _, model: Model in models do
			model:Destroy()
		end
	end)

	Networking.SendReliable = originalSendReliable

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
		clients = Scenario.clients,
		cases = cases,
		ticks = ticks,
	})
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 35

	while not predicate() do
		assert(not finished and os.clock() < deadline, reason)
		task.wait(0.01)
	end
end

local function replyCount(): number
	local count: number = 0

	for _ in replies do
		count += 1
	end

	return count
end

local function request(kind: string, extra: any?): ()
	phase = tostring(#cases) .. ":" .. tostring(#subjects) .. ":" .. kind
	replies = {}

	local message: any = extra or {}
	message.kind, message.phase = kind, phase

	local payload: buffer = buffer.fromstring(HttpService:JSONEncode(message))

	for player: Player in ready do
		control:FireClient(player, payload)
	end
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		assert(player.Parent == Players and typeof(payload) == "buffer", "Expected native client report")
		local report: any = HttpService:JSONDecode(buffer.tostring(payload))
		assert(report.failure == nil, player.Name .. ": " .. tostring(report.failure))

		if report.kind == "Ready" then
			assert(phase == "Ready" and not ready[player] and Networking.IsClientReady(player), "Invalid readiness")
			ready[player] = true
		elseif report.kind == "Wave" then
			assert(report.phase == phase and ready[player], "Unexpected wave phase")
			local wave: number = report.wave
			assert(wave % 1 == 0 and wave >= 1 and wave <= expectedRounds, "Unexpected wave number")
			local responses: { [Player]: any } = waveReplies[wave] or {}
			assert(responses[player] == nil and #report.observed == #subjects, "Duplicate or incomplete wave")
			assert(waveStarts[wave] ~= nil and starts[wave] ~= nil, "Client acknowledged uncommitted work")
			responses[player] = report
			waveReplies[wave] = responses
			table.insert(waveAckMs, (os.clock() - waveStarts[wave]) * 1000)

			for index: number, timestamp: number in report.observed do
				assert(math.isfinite(timestamp), "Invalid client timestamp")
				-- Keep signed estimates: synchronized-clock error must remain visible.
				table.insert(observedMs, (timestamp - starts[wave][index]) * 1000)
			end
		else
			assert(
				report.phase == phase and ready[player] and replies[player] == nil,
				"Unexpected/duplicate phase report"
			)

			replies[player] = report
		end
	end)

	if not completed then
		finish(false, tostring(reason))
	end
end)

local function controllerFor(actor: ActorTypes.Actor): TagTypes.InternalTagController
	local controller: TagTypes.InternalTagController? =
		actor:GetController("TagController") :: TagTypes.InternalTagController?

	assert(controller ~= nil, "Ordinary registration did not install TagController")

	return controller
end

local function seed(actor: ActorTypes.Actor): ActorTypes.Controller
	local controller: TagTypes.InternalTagController = controllerFor(actor)

	for id: string, count: number in Scenario.baseCounts do
		for _ = 1, count do
			local added: boolean, reason: string? = controller:AddTag(id)
			assert(added, reason)
		end
	end

	assert(controller:AddTag("Private.AIAlert"), "Expected private seed")
	assert(controller:AddTag("Private.Cooldown"), "Expected private seed")

	return { Destroy = function() end }
end

local function mutate(controller: TagTypes.InternalTagController, generation: number): ()
	controller:_beginMutationBatch()
	assert(controller:AddTag("Buff.Combo"), "Expected Combo stack")
	assert(controller:AddTag("Buff.Haste", { duration = 120 + generation }), "Expected timed refresh")
	assert(controller:AddTag("Status.Burning", { duration = 200 + generation }), "Expected stack-cap refresh")

	if generation % 2 == 1 then
		assert(controller:AddTag("Status.Stunned", { duration = 30 }), "Expected Stunned add")
	else
		assert(controller:RemoveTag("Status.Stunned"), "Expected Stunned removal")
	end

	assert(controller:AddTag("Private.AIAlert"), "Expected ignored private refresh")
	controller:_dispatchMutationEvents(controller:_finishMutationBatch())
end

local function runLoad(mode: string, rounds: number, firstGeneration: number): ()
	expectedRounds = rounds
	waveReplies, starts, waveStarts, waveAckMs, observedMs, cpuUs, framesMs = {}, {}, {}, {}, {}, {}, {}
	request("Arm", { mode = mode, rounds = rounds, firstGeneration = firstGeneration })

	waitFor(function(): boolean
		return replyCount() == Scenario.clients
	end, "Clients did not arm")

	for _, reply: any in replies do
		assert(reply.kind == "Armed", "Expected armed clients")
	end

	replies = {}
	local commitsBefore: number = commits
	sentTraffic = {}
	local started: number = os.clock()
	measuring = true

	for wave: number = 1, rounds do
		if mode == "Steady" then
			local remaining: number = started + (wave - 1) * Scenario.intervalSeconds - os.clock()

			if remaining > 0 then
				task.wait(remaining)
			end
		end

		starts[wave] = {}
		waveStarts[wave] = os.clock()

		local generation: number = firstGeneration + wave - 1

		for index: number, actor: ActorTypes.Actor in subjects do
			local controller: TagTypes.InternalTagController = controllerFor(actor)

			starts[wave][index] = workspace:GetServerTimeNow()

			local before: number = os.clock()
			mutate(controller, generation)
			table.insert(cpuUs, (os.clock() - before) * 1000000)
		end

		lastGeneration = generation
	end

	local mutationWindowSeconds: number = os.clock() - started

	waitFor(function(): boolean
		return replyCount() == Scenario.clients
	end, "Clients lost state changes or semantic events under load")

	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	measuring = false
	assert(commits - commitsBefore == #subjects * rounds, "Lost or extra N3 commits")
	assert(#observedMs == #subjects * rounds * Scenario.clients, "Incomplete application samples")
	assert(#waveAckMs == rounds * Scenario.clients, "Incomplete wave acknowledgements")
	local clientMetrics: { any } = {}

	for player: Player, reply: any in replies do
		assert(
			reply.kind == "Done" and reply.states == #subjects * rounds and reply.events == #subjects * rounds * 4,
			"Incomplete client work"
		)

		local traffic = sentTraffic[player]

		assert(
			traffic ~= nil
				and traffic.bytes == reply.metrics.payloadBytes
				and traffic.packets == reply.metrics.actorPackets,
			"Transport counters omitted or double-counted framework packets"
		)

		table.insert(clientMetrics, {
			player = player.Name,
			metrics = reply.metrics,
			serverSentPayloadBytes = traffic.bytes,
			serverSentActorPackets = traffic.packets,
		})
	end

	table.insert(cases, {
		actors = #subjects,
		mode = mode,
		rounds = rounds,
		requestedWaveIntervalSeconds = if mode == "Steady" then Scenario.intervalSeconds else 0,
		mutationWindowSeconds = mutationWindowSeconds,
		committedBatches = commits - commitsBefore,
		serverMutationUs = Scenario.summarize(cpuUs),
		serverHeartbeatMs = Scenario.summarize(framesMs),
		consumerObservedEstimateMs = Scenario.summarize(observedMs),
		waveCompletionAckMs = Scenario.summarize(waveAckMs),
		clients = clientMetrics,
	})
end

local definitions: { TagTypes.TagDefinition } = {
	{ id = "State.Alive", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
	{ id = "State.Combat", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
	{ id = "Movement.Grounded", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
	{ id = "Buff.Combo", visibility = "ClientVisible", duplicateBehavior = "Stack", maxStacks = 32 },
	{ id = "Buff.Haste", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 300 },
	{ id = "Buff.Fortified", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 300 },
	{
		id = "Buff.Regeneration",
		visibility = "ClientVisible",
		duplicateBehavior = "Refresh",
		defaultDuration = 300,
		tickInterval = 0.5,
		onTick = function()
			ticks += 1
		end,
	},
	{
		id = "Status.Burning",
		visibility = "ClientVisible",
		duplicateBehavior = "Stack",
		maxStacks = 3,
		defaultDuration = 300,
	},
	{
		id = "Status.Poison",
		visibility = "ClientVisible",
		duplicateBehavior = "Stack",
		maxStacks = 2,
		defaultDuration = 300,
	},
	{ id = "Status.Stunned", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 30 },
	{ id = "Private.AIAlert", visibility = "ServerOnly", duplicateBehavior = "Refresh", defaultDuration = 300 },
	{
		id = "Private.Cooldown",
		visibility = "ServerOnly",
		duplicateBehavior = "Refresh",
		defaultDuration = 300,
		tickInterval = 0.5,
		onTick = function()
			ticks += 1
		end,
	},
}

local initialized: boolean, failure: Server.StartupFailure? = Server.Init({
	tags = definitions,
	controllers = { { key = "Game.LoadSeed", dependsOn = { "TagController" }, factory = seed } },
})

if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Server.Init failed")
else
	task.delay(180, function()
		finish(false, "Load fixture timed out in " .. phase)
	end)

	task.spawn(function()
		local completed: boolean, reason: any = pcall(function()
			waitFor(function(): boolean
				return #Players:GetPlayers() == Scenario.clients
					and ready[Players:GetPlayers()[1]] == true
					and ready[Players:GetPlayers()[2]] == true
			end, "Expected two real ready clients")

			local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
			assert(publication ~= nil, "Expected ordinary N3 runtime")

			disconnectPublication = publication:ObserveCommits(function()
				commits += 1
			end)

			for _, actorCount: number in Scenario.actorCounts do
				local actorIds: { string } = {}

				for index: number = 1, actorCount do
					local model: Model = Instance.new("Model")
					model.Name = "LoadSubject" .. index

					local root: Part = Instance.new("Part")
					root.Anchored = true
					root.Position = Vector3.new((index % 10) * 8, 5, math.floor(index / 10) * 8)
					root.Parent = model
					model.PrimaryPart = root
					model.Parent = workspace
					table.insert(models, model)
					local actor: ActorTypes.Actor?, registerReason: string? = Actors.RegisterActor(model)
					assert(actor ~= nil, registerReason)
					table.insert(subjects, actor)
					table.insert(actorIds, actor:GetId())
				end

				lastGeneration = 0
				request("Baseline", { actorIds = actorIds })

				waitFor(function(): boolean
					return replyCount() == Scenario.clients
				end, "Initial native baselines did not install")

				task.wait(0.3)
				request("Quiet")
				local beforeQuiet: number = commits

				for _, actor: ActorTypes.Actor in subjects do
					assert(controllerFor(actor):AddTag("Private.AIAlert"), "Expected private-only refresh")
				end

				waitFor(function(): boolean
					return replyCount() == Scenario.clients
				end, "Countdown/private quiet check failed")

				assert(commits == beforeQuiet and ticks > 0, "Quiet interval created commits or failed to tick")
				runLoad("Steady", Scenario.steadyRounds, 1)
				runLoad("Burst", Scenario.burstRounds, lastGeneration + 1)

				for _, actor: ActorTypes.Actor in subjects do
					assert(Actors.UnregisterActor(actor), "Expected authoritative removal")
				end

				request("Retire")

				waitFor(function(): boolean
					return replyCount() == Scenario.clients
				end, "Retired Actors retained client truth")

				for _, model: Model in models do
					model:Destroy()
				end

				subjects, models = {}, {}
			end

			request("Reset")

			waitFor(function(): boolean
				return replyCount() == Scenario.clients
			end, "Client reset did not complete")
		end)

		finish(completed, if completed then nil else tostring(reason))
	end)
end
