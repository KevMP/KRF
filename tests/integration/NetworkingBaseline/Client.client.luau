--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Client = require(KRF.client)
local ActorStream = require(KRF.client.Networking.ActorStreamRuntime)
local Registry: Types.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Transport = require(KRF.shared.Networking.Transport)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Scenario = require(ReplicatedStorage.NetworkingBaselineScenario)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent

local reliable: RemoteEvent =
	ReplicatedStorage:WaitForChild(Transport.ROOT_NAME):WaitForChild(Transport.RELIABLE_NAME) :: RemoteEvent

local phase = "Ready"
local measuring, completing, failed = false, false, false
local subjects: { Types.ActorView } = {}
local connections: { SignalTypes.Connection } = {}
local previous: { number } = {}
local expected: { number } = {}
local seen: { { [number]: boolean } } = {}
local observed: { { number } } = {}
local audited: { any } = {}
local actorEvents: { number } = {}
local states, events, packets, bytes = 0, 0, 0, 0
local frames: { number } = {}
local handlerUs: { number } = {}
local heapKiB: { number } = {}
local renderMs: { number } = {}
local epoch = 0
local originalHandle = ActorStream.Handle

-- Delegate to the installed production consumer, including decode/application.
-- This excludes deferred public listeners and is elapsed wall time, not OS CPU.
ActorStream.Handle = function(...: any): (boolean, string?)
	local started = os.clock()
	local success, reason = originalHandle(...)

	if measuring then
		table.insert(handlerUs, (os.clock() - started) * 1e6)
	end

	return success, reason
end

local function report(kind: string, extra: any?): ()
	local message = extra or {}
	message.kind, message.phase = kind, phase
	control:FireServer(buffer.fromstring(HttpService:JSONEncode(message)))
end

local function guard(callback: () -> ()): ()
	if failed then
		return
	end

	local ok, reason = pcall(callback)

	if not ok then
		failed = true
		report("Failed", { failure = tostring(reason) })
	end
end

local function waitFor(predicate: () -> boolean): ()
	local deadline = os.clock() + 30

	while not predicate() do
		assert(os.clock() < deadline, "Native client timeout")
		task.wait(0.01)
	end
end

local endpoint = reliable.OnClientEvent:Connect(function(payload: any)
	guard(function()
		assert(typeof(payload) == "buffer", "Expected buffer")
		assert(not string.find(buffer.tostring(payload), "Private.", 1, true), "Private ID leak")

		if measuring and buffer.readu8(payload, 0) == Constants.PACKET_KIND then
			packets += 1
			bytes += buffer.len(payload)
		end
	end)
end)

local heartbeat = RunService.Heartbeat:Connect(function(delta: number)
	if measuring then
		table.insert(frames, delta * 1000)
		table.insert(heapKiB, gcinfo())
	end
end)

local render = RunService.RenderStepped:Connect(function(delta: number)
	if measuring then
		table.insert(renderMs, delta * 1000)
	end
end)

local function maybeComplete(): ()
	local total = 0

	for _, count in expected do
		total += count
	end

	if completing or states ~= total or events ~= total then
		return
	end

	completing = true

	task.defer(function()
		RunService.Heartbeat:Wait()

		guard(function()
			assert(states == total and events == total, "Extra delivery")
			measuring = false

			for _, audit in audited do
				Scenario.verify(audit.state, audit.index)

				for id, entry in audit.state do
					if id ~= "Bench.Tag1" then
						assert(entry.expiresAt == audit.baseline[id].expiresAt, "Untouched timing drift")
					end
				end
			end

			for index, count in expected do
				assert(actorEvents[index] == count, "Semantic occurrences attributed to the wrong Actor")

				for ordinal = 1, count do
					assert(seen[index][previous[index] + ordinal], "Missing generation")
				end
			end

			report("Done", {
				states = states,
				events = events,
				packets = packets,
				bytes = bytes,
				observed = observed,
				heartbeatMs = Scenario.summarize(frames),
				rawHeartbeatMs = frames,
				handlerUs = Scenario.summarize(handlerUs),
				rawHandlerUs = handlerUs,
				renderMs = Scenario.summarize(renderMs),
				rawRenderMs = renderMs,
				rawHeapKiB = heapKiB,
			})
		end)
	end)
end

control.OnClientEvent:Connect(function(payload: any)
	guard(function()
		local message = HttpService:JSONDecode(buffer.tostring(payload))
		phase = message.phase

		if message.kind == "Baseline" then
			waitFor(function(): boolean
				if #Registry.GetAllActorViews() ~= #message.actorIds then
					return false
				end

				for _, id in message.actorIds do
					local view = Registry.GetActorViewById(id)

					if view == nil or view:GetModel() == nil then
						return false
					end
				end

				return true
			end)

			for index, id in message.actorIds do
				local view = Registry.GetActorViewById(id)
				assert(view ~= nil, "Missing native ActorView")
				table.insert(subjects, view)
				local domain = view:GetDomain("KRF.Tags")
				assert(domain ~= nil, "Missing native Tags domain")
				local baseline: any = domain:GetState()
				Scenario.verify(baseline, index)

				table.insert(
					connections,
					domain.OnChanged:Connect(function(change: Types.DomainChange)
						local timestamp = workspace:GetServerTimeNow()

						guard(function()
							assert(measuring and change.source == "Commit", "Unexpected baseline/recovery")

							local generation =
								math.round((change.current["Bench.Tag1"].expiresAt - epoch - 10000) / 100)

							assert(
								generation > previous[index] and generation <= previous[index] + expected[index],
								"Unexpected generation"
							)

							assert(not seen[index][generation], "Duplicate generation")
							seen[index][generation] = true
							observed[index][generation - previous[index]] = timestamp
							states += 1
							table.insert(audited, { state = change.current, baseline = baseline, index = index })
							maybeComplete()
						end)
					end)
				)

				table.insert(
					connections,
					view:GetTags().OnTagRefreshed:Connect(function(tagId: string)
						guard(function()
							assert(measuring and tagId == "Bench.Tag1", "Unexpected semantic occurrence")
							events += 1
							actorEvents[index] += 1
							maybeComplete()
						end)
					end)
				)
			end

			report("Baseline")
		elseif message.kind == "Quiet" then
			packets, bytes = 0, 0
			frames, renderMs, heapKiB, handlerUs = {}, {}, {}, {}
			measuring = true
			task.wait(2)
			measuring = false
			assert(packets == 0 and bytes == 0, "Countdown traffic")

			report("Quiet", {
				heartbeatMs = Scenario.summarize(frames),
				renderMs = Scenario.summarize(renderMs),
				heapKiB = Scenario.summarize(heapKiB),
			})
		elseif message.kind == "Arm" then
			epoch, previous = message.epoch, message.previous
			expected = Scenario.counts(Scenario.plan(#subjects, message.mode), #subjects)
			seen, observed, audited, frames = {}, {}, {}, {}
			handlerUs, heapKiB, renderMs = {}, {}, {}
			actorEvents = table.create(#subjects, 0)

			for index = 1, #subjects do
				seen[index], observed[index] = {}, {}
			end

			states, events, packets, bytes = 0, 0, 0, 0
			completing, measuring = false, true
			report("Armed")
		elseif message.kind == "Retire" then
			waitFor(function(): boolean
				return #Registry.GetAllActorViews() == 0
			end)

			for _, view in subjects do
				assert(#view:GetTags():GetActiveTags() == 0, "Retired Tags retained")
			end

			for _, connection in connections do
				connection:Disconnect()
			end

			connections, subjects = {}, {}
			report("Retire")
		elseif message.kind == "Reset" then
			Client._ResetForTests()
			assert(#Registry.GetAllActorViews() == 0, "Reset retained ActorViews")
			endpoint:Disconnect()
			heartbeat:Disconnect()
			render:Disconnect()
			ActorStream.Handle = originalHandle
			report("Reset")
		else
			error("Unknown baseline phase", 0)
		end
	end)
end)

local initialized, failure = Client.Init()

if initialized then
	report("Ready")
else
	report("Failed", { failure = if failure ~= nil then failure.reason else "Startup failed" })
end
