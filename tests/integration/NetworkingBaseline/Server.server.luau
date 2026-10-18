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
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Scenario = require(ReplicatedStorage.NetworkingBaselineScenario)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent

Players.CharacterAutoLoads = false

local subjects: { ActorTypes.Actor } = {}
local models: { Model } = {}
local ready: { [Player]: boolean } = {}
local replies: { [Player]: any } = {}
local sent: { [Player]: { bytes: number, packets: number } } = {}
local starts: { { number } } = {}
local generations: { number } = {}
local cases: { any } = {}
local frames: { number } = {}
local frameTimes: { number } = {}
local packetSizes: { number } = {}
local steps: { { number } } = {}
local measuring, finished = false, false
local phase = "Ready"
local commits = 0
local caseStart = 0
local heap: { { number } } = {}
local originalSend = Networking.SendReliable
local originalStep = Awareness.Step

Awareness.Step = function(...: any): ()
	local started = os.clock()
	originalStep(...)

	if measuring then
		table.insert(steps, { started - caseStart, (os.clock() - started) * 1e6 })
	end
end

Networking.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
	local success, reason = originalSend(player, payload)

	if measuring and success and buffer.readu8(payload, 0) == Constants.PACKET_KIND then
		local traffic = sent[player] or { bytes = 0, packets = 0 }
		traffic.bytes += buffer.len(payload)
		traffic.packets += 1
		sent[player] = traffic
		table.insert(packetSizes, buffer.len(payload))
	end

	return success, reason
end

local heartbeat = RunService.Heartbeat:Connect(function(delta: number)
	if measuring then
		table.insert(frames, delta * 1000)
		table.insert(frameTimes, os.clock() - caseStart)
		table.insert(heap, { os.clock() - caseStart, gcinfo() })
	end
end)

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	heartbeat:Disconnect()

	local cleaned, cleanupReason = pcall(function()
		for _, actor in subjects do
			Actors.UnregisterActor(actor)
		end

		Networking.Destroy()

		for _, model in models do
			model:Destroy()
		end
	end)

	Networking.SendReliable = originalSend
	Awareness.Step = originalStep

	StudioTestService:EndTest({
		success = success and cleaned,
		reason = reason or (if cleaned then nil else tostring(cleanupReason)),
		phase = phase,
		clients = 2,
		cases = cases,
	})
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline = os.clock() + 35

	while not predicate() do
		assert(not finished and os.clock() < deadline, reason)
		task.wait(0.01)
	end
end

local function replyCount(): number
	local count = 0

	for _ in replies do
		count += 1
	end

	return count
end

local function request(kind: string, extra: any?): ()
	phase = tostring(#cases) .. ":" .. tostring(#subjects) .. ":" .. kind
	replies = {}

	local message = extra or {}
	message.kind, message.phase = kind, phase

	for player in ready do
		control:FireClient(player, buffer.fromstring(HttpService:JSONEncode(message)))
	end

	waitFor(function(): boolean
		return replyCount() == 2
	end, "Incomplete native " .. kind)
end

control.OnServerEvent:Connect(function(player: Player, payload: any)
	if finished then
		return
	end

	local ok, reason = pcall(function()
		assert(player.Parent == Players and typeof(payload) == "buffer", "Expected native client")
		local report = HttpService:JSONDecode(buffer.tostring(payload))
		assert(report.failure == nil, tostring(report.failure))

		if report.kind == "Ready" then
			assert(Networking.IsClientReady(player) and not ready[player], "Bad READY")
			ready[player] = true
		else
			assert(report.phase == phase and replies[player] == nil, "Duplicate/wrong phase")
			report.serverAckAt = os.clock()
			replies[player] = report
		end
	end)

	if not ok then
		finish(false, tostring(reason))
	end
end)

local function controllerFor(actor: ActorTypes.Actor): TagTypes.TagController
	local controller = actor:GetController("TagController") :: TagTypes.TagController?
	assert(controller ~= nil, "Missing ordinary TagController")

	return controller
end

local definitions: { TagTypes.TagDefinition } = {}

for index = 1, 5 do
	local definition: TagTypes.TagDefinition = {
		id = "Bench.Tag" .. index,
		visibility = "ClientVisible",
		duplicateBehavior = "Stack",
		maxStacks = if index == 1 then 1 else 3,
		defaultDuration = 10000,
	}

	table.insert(definitions, definition)
end

local privateDefinition: TagTypes.TagDefinition =
	{ id = "Private.Hidden", visibility = "ServerOnly", duplicateBehavior = "Refresh", defaultDuration = 10000 }

table.insert(definitions, privateDefinition)

local seedIndex = 0

local initialized, failure = Server.Init({
	tags = definitions,
	controllers = {
		{
			key = "Game.BaselineSeed",
			dependsOn = { "TagController" },
			factory = function(actor: ActorTypes.Actor): ActorTypes.Controller
				seedIndex += 1
				local controller = controllerFor(actor)

				for tagIndex = 1, 1 + (seedIndex - 1) % 5 do
					for _ = 1, (if tagIndex == 1 then 1 else 1 + (seedIndex + tagIndex) % 3) do
						assert(controller:AddTag("Bench.Tag" .. tagIndex))
					end
				end

				assert(controller:AddTag("Private.Hidden"))

				return { Destroy = function() end }
			end,
		},
	},
})

if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Startup failed")
else
	task.delay(180, function()
		finish(false, "Baseline timeout")
	end)

	task.spawn(function()
		local ok, reason = pcall(function()
			waitFor(function(): boolean
				local players = Players:GetPlayers()

				return #players == 2 and ready[players[1]] == true and ready[players[2]] == true
			end, "Expected two real clients")

			local publication = Networking._GetPublicationRuntimeForTests()
			assert(publication ~= nil, "Missing startup-owned N3 runtime")

			publication:ObserveCommits(function()
				commits += 1
			end)

			for _, population in Scenario.populations do
				seedIndex = 0
				local ids: { string } = {}

				for index = 1, population.actors do
					local model = Instance.new("Model")

					local part = Instance.new("Part")
					part.Anchored = true
					part.Position = Vector3.new(index % 10 * 8, 5, math.floor(index / 10) * 8)
					part.Parent = model
					model.PrimaryPart = part
					model.Parent = workspace
					table.insert(models, model)
					local actor, registerReason = Actors.RegisterActor(model)
					assert(actor ~= nil, registerReason)
					table.insert(subjects, actor)
					table.insert(ids, actor:GetId())
				end

				generations = table.create(#subjects, 0)
				request("Baseline", { actorIds = ids })
				request("Quiet")
				local beforeQuiet = commits

				for _, actor in subjects do
					assert(controllerFor(actor):AddTag("Private.Hidden"))
				end

				task.wait(0.25)
				assert(commits == beforeQuiet, "Private mutations published")

				for _, mode in Scenario.modes do
					local plan = Scenario.plan(#subjects, mode)
					local epoch = workspace:GetServerTimeNow()
					request("Arm", { mode = mode, epoch = epoch, previous = generations })
					frames, frameTimes, heap, starts, sent, packetSizes, steps = {}, {}, {}, {}, {}, {}, {}
					local mutationUs: { number } = {}
					local tickCpuUs: { number } = {}
					local tickTimes: { number } = {}
					local expected = 0
					local beforeCommits = commits
					caseStart = os.clock()
					measuring = true
					replies = {}

					for tick, indices in plan do
						local remaining = caseStart + (tick - 1) / Scenario.hz - os.clock()

						if remaining > 0 then
							task.wait(remaining)
						end

						local tickStart = os.clock()
						table.insert(tickTimes, tickStart - caseStart)

						for _, index in indices do
							generations[index] += 1

							local generation = generations[index]

							starts[index] = starts[index] or {}
							table.insert(starts[index], workspace:GetServerTimeNow())
							local controller = controllerFor(subjects[index])
							local before = os.clock()

							assert(
								controller:AddTag(
									"Bench.Tag1",
									{ duration = epoch + 10000 + generation * 100 - workspace:GetServerTimeNow() }
								)
							)

							table.insert(mutationUs, (os.clock() - before) * 1e6)
							expected += 1
						end

						table.insert(tickCpuUs, (os.clock() - tickStart) * 1e6)
					end

					waitFor(function(): boolean
						return replyCount() == 2
					end, "Lost native generations/events")

					RunService.Heartbeat:Wait()
					RunService.Heartbeat:Wait()
					measuring = false
					assert(commits - beforeCommits == expected, "Lost N3 commits")
					local observed: { number } = {}
					local clients: { any } = {}

					for player, reply in replies do
						assert(reply.states == expected and reply.events == expected, "Incomplete delivery")

						assert(
							sent[player].bytes == reply.bytes and sent[player].packets == reply.packets,
							"Send/receive mismatch"
						)

						for index, times in reply.observed do
							for ordinal, timestamp in times do
								table.insert(observed, (timestamp - starts[index][ordinal]) * 1000)
							end
						end

						table.insert(clients, reply)
					end

					table.insert(cases, {
						actors = #subjects,
						modeledPlayers = population.players,
						mode = mode,
						commits = expected,
						seconds = os.clock() - caseStart,
						mutationUs = Scenario.summarize(mutationUs),
						tickCpuUs = Scenario.summarize(tickCpuUs),
						serverHeartbeatMs = Scenario.summarize(frames),
						observedMs = Scenario.summarize(observed),
						packetBytes = Scenario.summarize(packetSizes),
						clients = clients,
						raw = {
							mutationUs = mutationUs,
							tickCpuUs = tickCpuUs,
							tickTimes = tickTimes,
							serverHeartbeatMs = frames,
							frameTimes = frameTimes,
							heapKiB = heap,
							n4Steps = steps,
							observedMs = observed,
							packetBytes = packetSizes,
						},
					})
				end

				for _, actor in subjects do
					assert(Actors.UnregisterActor(actor))
				end

				request("Retire")

				for _, model in models do
					model:Destroy()
				end

				subjects, models = {}, {}
			end

			request("Reset")
		end)

		finish(ok, if ok then nil else tostring(reason))
	end)
end
