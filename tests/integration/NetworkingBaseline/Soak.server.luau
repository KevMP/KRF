--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local LogService = game:GetService("LogService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local Server = require(KRF.server)
local Actors = require(KRF.server.Actor.ActorRuntime)
local Registry = require(KRF.server.Actor.ActorRegistry)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local State = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local Soak = require(ReplicatedStorage.NetworkingSoak)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent
local args = StudioTestService:GetTestArgs()
local smoke = type(args) == "table" and args.soakSmoke == true
local durations = if smoke then { 10, 30, 30, 10 } else { 300, 1080, 1080, 240 }

local minuteInterval, quietInterval, rotationInterval =
	if smoke then 10 else 60, if smoke then 20 else 300, if smoke then 15 else 60

type Slot = { actor: ActorTypes.Actor, model: Model }
local slots: { Slot } = {}
local ready: { [Player]: boolean } = {}
local replies: { [Player]: any } = {}
local checkpoints: { any } = {}
local sequence, mutations, replacements, cursor, rotation = 0, 0, 0, 0, 0
local failure: string? = nil
local finished = false
local start = 0
local phase = "Startup"
local warnings, errors = 0, 0
local histogram = Soak.histogram()
local originalStep = Awareness.Step

Players.CharacterAutoLoads = false

Awareness.Step = function(...: any): ()
	local before = os.clock()
	originalStep(...)
	Soak.observe(histogram, (os.clock() - before) * 1e6)
end

local logs = LogService.MessageOut:Connect(function(message: string, kind: Enum.MessageType)
	if string.find(message, "[Networking", 1, true) then
		if kind == Enum.MessageType.MessageWarning then
			warnings += 1
		elseif kind == Enum.MessageType.MessageError then
			errors += 1
		end
	end
end)

local endpoint = control.OnServerEvent:Connect(function(player: Player, payload: buffer)
	local ok, reason = pcall(function()
		local message = HttpService:JSONDecode(buffer.tostring(payload))
		assert(player.Parent == Players and message.failure == nil, tostring(message.failure))

		if message.kind == "Ready" then
			assert(Networking.IsClientReady(player) and not ready[player], "Invalid client Ready")
			ready[player] = true
		else
			assert(ready[player] and message.sequence == sequence and replies[player] == nil, "Unexpected reply")
			message.clientId = player.UserId
			replies[player] = message
		end
	end)

	if not ok then
		failure = tostring(reason)
	end
end)

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline = os.clock() + 35

	while not predicate() do
		assert(failure == nil, failure)
		assert(os.clock() < deadline, reason)
		task.wait(0.05)
	end

	assert(failure == nil, failure)
end

local function controller(actor: ActorTypes.Actor): TagTypes.TagController
	local value = actor:GetController("TagController") :: TagTypes.TagController?
	assert(value ~= nil, "Missing normal TagController")

	return value
end

local function create(index: number): Slot
	local model = Instance.new("Model")
	model.Name = "NetworkingSoak"

	local part = Instance.new("Part")
	part.Anchored = true
	part.Position = Vector3.new(index % 10 * 8, 5, math.floor(index / 10) * 8)
	part.Parent = model
	model.PrimaryPart = part
	model.Parent = workspace
	local actor, reason = Actors.RegisterActor(model)
	assert(actor ~= nil, reason)
	local tags = controller(actor):GetTagInstances("Soak.Pulse")
	assert(#tags == 1, "Missing seeded public Tag")

	return { actor = actor, model = model }
end

local function retire(slot: Slot): ()
	local id = slot.actor:GetId()
	Actors.UnregisterActor(slot.actor)
	assert(Registry.GetActorById(id) == nil, "Retained server Actor registration")
	slot.model:Destroy()
end

local function checkpoint(kind: string, quiet: boolean): ()
	local owner = State.GetServer()
	assert(owner ~= nil, "Missing server diagnostics")

	if quiet then
		-- No forced collection: give pending production work/listeners time to drain.
		task.wait(if smoke then 0.5 else 3)

		waitFor(function(): boolean
			local gauges = owner:Snapshot().gauges

			return gauges.reliableRecords.current == 0 and gauges.baselineGenerations.current == 0
		end, "Server failed to drain")

		Soak.assertDrained(owner:Snapshot(), false)
	end

	sequence += 1
	table.clear(replies)
	local expected = {}

	if quiet then
		local domain = Domains.Get("KRF.Tags")
		assert(domain ~= nil, "Missing built-in Tags domain")

		for _, slot in slots do
			local current = domain.snapshot(slot.actor)
			table.insert(expected, { id = slot.actor:GetId(), expiresAt = current["Soak.Pulse"].expiresAt })
		end
	end

	control:FireAllClients(buffer.fromstring(HttpService:JSONEncode({
		kind = kind,
		sequence = sequence,
		quiet = quiet,
		expected = expected,
		events = mutations,
	})))

	waitFor(function(): boolean
		local count = 0

		for _ in replies do
			count += 1
		end

		return count == 2
	end, "Two-client checkpoint timeout")

	local clients = {}

	for player, sample in replies do
		assert(player.Parent == Players and Networking.IsClientReady(player), "Client disconnected")
		table.insert(clients, sample)
	end

	local sample = Soak.read(owner)
	sample.elapsedSeconds, sample.phase, sample.kind = os.clock() - start, phase, kind
	sample.actors, sample.mutations, sample.replacements = #slots, mutations, replacements
	sample.warnings, sample.errors, sample.clients = warnings, errors, clients
	sample.pump = Soak.summarize(histogram)
	table.insert(checkpoints, sample)
	histogram = Soak.histogram()
	print("__KRF_SOAK_CHECKPOINT__", sequence, phase, math.round(sample.elapsedSeconds), sample.heapKiB)
end

task.spawn(function()
	local ok, reason = pcall(function()
		local initialized, initFailure = Server.Init({
			tags = {
				{
					id = "Soak.Pulse",
					visibility = "ClientVisible",
					duplicateBehavior = "Refresh",
					defaultDuration = 10000,
				},
			},
			controllers = {
				{
					key = "Game.SoakSeed",
					dependsOn = { "TagController" },
					factory = function(actor: ActorTypes.Actor): ActorTypes.Controller
						assert(controller(actor):AddTag("Soak.Pulse"))

						return { Destroy = function() end }
					end,
				},
			},
		})

		assert(initialized, tostring(initFailure))

		waitFor(function(): boolean
			local count = 0

			for _ in ready do
				count += 1
			end

			return count == 2 and #Players:GetPlayers() == 2
		end, "Native clients did not start")

		for index = 1, 75 do
			slots[index] = create(index)
		end

		start = os.clock()
		local nextMinute, nextQuiet = minuteInterval, quietInterval
		local deadline = 0

		for phaseIndex, duration in durations do
			phase = ({ "Warmup", "Moderate", "Medium", "Cleanup" })[phaseIndex]
			deadline += duration
			local nextMutation = os.clock()
			local nextRotation = os.clock() + rotationInterval

			if phaseIndex == 4 then
				for _, slot in slots do
					retire(slot)
				end

				table.clear(slots)
			end

			checkpoint("PhaseStart", true)

			while os.clock() - start < deadline do
				assert(failure == nil, failure)
				local now = os.clock()
				local elapsed = now - start

				if elapsed >= nextMinute then
					local quiet = elapsed >= nextQuiet
					checkpoint(if quiet then "Quiet" else "Minute", quiet)
					nextMinute += minuteInterval

					if quiet then
						nextQuiet += quietInterval
					end
				elseif (phaseIndex == 2 or phaseIndex == 3) and now >= nextRotation then
					for _ = 1, 3 do
						rotation = rotation % 75 + 1
						retire(slots[rotation])
						slots[rotation] = create(rotation)
						replacements += 1
					end

					nextRotation = now + rotationInterval
				elseif (phaseIndex == 2 or phaseIndex == 3) and now >= nextMutation then
					for _ = 1, (if phaseIndex == 2 then 5 else 10) do
						cursor = cursor % 75 + 1
						local slot = slots[cursor]
						assert(controller(slot.actor):AddTag("Soak.Pulse"))
						mutations += 1
					end

					-- Skip missed ticks rather than introducing catch-up bursts.
					nextMutation = now + (if phaseIndex == 2 then 0.2 else 0.1)
				end

				task.wait(0.02)
			end

			checkpoint("PhaseEnd", true)
		end

		checkpoint("FinalQuiet", true)
		checkpoint("Destroy", true)
	end)

	for _, slot in slots do
		retire(slot)
	end

	table.clear(slots)
	local owner = State.GetServer()
	Networking.Destroy()
	Awareness.Step = originalStep
	endpoint:Disconnect()
	logs:Disconnect()
	local final = if owner ~= nil then Soak.read(owner) else nil

	local cleaned, cleanupReason = pcall(function()
		assert(owner ~= nil and State.GetServer() == nil, "Server Networking survived teardown")
		Soak.assertDrained(owner:Snapshot(), true)
	end)

	finished = true

	StudioTestService:EndTest({
		success = ok and cleaned,
		reason = if not ok then tostring(reason) elseif not cleaned then tostring(cleanupReason) else nil,
		clients = 2,
		workload = "MemorySoak",
		smoke = smoke,
		phase = phase,
		requestedPhaseSeconds = durations,
		durationSeconds = os.clock() - start,
		checkpoints = checkpoints,
		finalServer = final,
		memoryVerdict = "Requires quiet-floor review; success asserts workload and ownership only",
	})
end)

task.delay(if smoke then 180 else 2880, function()
	if not finished then
		failure = "Soak fixture deadline exceeded"
	end
end)
