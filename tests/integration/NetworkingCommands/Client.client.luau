--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local PublicTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Client = require(KRF.client)
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local Commands: Types.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Scenario = require(ReplicatedStorage.NetworkingCommandScenario)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent
local phase = "Ready"
local view: PublicTypes.ActorView? = nil
local failed, measuring = false, false
local epoch, serial = 0, 0
local states, events, localRefused = 0, 0, 0
local uncertain = 0
local starts: { [number]: number } = {}
local serials: { [number]: number } = {}
local results: { [number]: boolean } = {}
local resultsBySerial: { [number]: boolean } = {}
local resultMs: { number } = {}
local heartbeatMs: { number } = {}
local renderMs: { number } = {}
local heapKiB: { number } = {}

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
	local deadline = os.clock() + 40

	while not predicate() do
		assert(not failed and os.clock() < deadline, "Native command client timeout")
		task.wait(0.01)
	end
end

local resultConnection = Commands.OnCommandResult:Connect(function(result: Types.CommandResult)
	guard(function()
		assert(measuring and result.status == "Accepted", "Unexpected/definitive result for refused work")
		assert(result.targetActorView == view and not results[result.requestId], "Wrong target or duplicate result")
		assert(serials[result.requestId] == result.result.serial, "Uncorrelated native result")
		results[result.requestId], resultsBySerial[result.result.serial] = true, true
		table.insert(resultMs, (os.clock() - starts[result.requestId]) * 1000)
	end)
end)

local uncertaintyConnection = Commands.OnCommandUncertain:Connect(function(result: Types.CommandResult)
	guard(function()
		assert(result.status == "Unknown", "Capacity refusal must not fabricate a definitive rejection")

		if measuring and starts[result.requestId] ~= nil then
			uncertain += 1
		end
	end)
end)

local heartbeat = RunService.Heartbeat:Connect(function(delta)
	if measuring then
		table.insert(heartbeatMs, delta * 1000)
		table.insert(heapKiB, gcinfo())
	end
end)

local render = RunService.RenderStepped:Connect(function(delta)
	if measuring then
		table.insert(renderMs, delta * 1000)
	end
end)

local domainConnection: SignalTypes.Connection? = nil
local tagConnection: SignalTypes.Connection? = nil

control.OnClientEvent:Connect(function(payload: buffer)
	guard(function()
		local message = HttpService:JSONDecode(buffer.tostring(payload))
		phase = message.phase

		if message.kind == "Prepare" then
			waitFor(function(): boolean
				view = Registry.GetActorViewById(message.actorId)

				return view ~= nil
					and view:IsAvailable()
					and view:GetModel() ~= nil
					and view:GetTags():GetTag("Bench.Command") ~= nil
			end)

			local domain = (view :: PublicTypes.ActorView):GetDomain("KRF.Tags")
			assert(domain ~= nil, "Normal consumer did not install Tags")

			domainConnection = domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
				guard(function()
					if not measuring then
						return
					end

					assert(change.source == "Commit" and table.isfrozen(change.current), "Invalid native state")
					local changedSerial = math.round((change.current["Bench.Command"].expiresAt - epoch - 10000) / 100)

					assert(
						resultsBySerial[changedSerial],
						"Requester effect callback overtook its actual result callback"
					)

					states += 1
				end)
			end)

			tagConnection = (view :: PublicTypes.ActorView):GetTags().OnTagRefreshed:Connect(function(tagId: string)
				guard(function()
					if measuring then
						assert(tagId == "Bench.Command", "Unexpected semantic event")
						events += 1
					end
				end)
			end)

			report("Prepared")
		elseif message.kind == "Run" then
			epoch = message.epoch
			states, events, localRefused = 0, 0, 0
			uncertain = 0
			starts, serials, results, resultsBySerial = {}, {}, {}, {}
			resultMs, heartbeatMs, renderMs, heapKiB = {}, {}, {}, {}
			measuring = true
			local sent = 0

			for tick = 1, Scenario.ticks do
				local remaining = epoch
					+ (tick - 1) / Scenario.hz
					+ Scenario.delay(tick, message.index, message.clients, message.mode)
					- workspace:GetServerTimeNow()

				if remaining > 0 then
					task.wait(remaining)
				end

				for _ = 1, Scenario.offered(tick, message.index, message.clients, message.mode) do
					serial += 1
					local started = os.clock()

					local id, reason =
						Commands.Send("Bench.Command", view, { serial = serial, sentAt = workspace:GetServerTimeNow() })

					if id ~= nil then
						starts[id], serials[id] = started, serial
						sent += 1
					else
						assert(type(reason) == "string", "Unexplained local refusal")
						localRefused += 1
					end
				end
			end

			report("Sent", { sent = sent })
		elseif message.kind == "Collect" then
			waitFor(function(): boolean
				for _, id in message.accepted do
					if not results[id] then
						return false
					end
				end

				return states == #message.accepted and events == #message.accepted
			end)

			local accepted: { [number]: boolean } = {}

			for _, id in message.accepted do
				accepted[id] = true
			end

			for id in results do
				assert(accepted[id], "Refused command produced a result/effect")
			end

			measuring = false

			report("Collected", {
				states = states,
				events = events,
				results = #message.accepted,
				localRefused = localRefused,
				uncertain = uncertain,
				resultMs = Scenario.summarize(resultMs),
				heartbeatMs = Scenario.summarize(heartbeatMs),
				renderMs = Scenario.summarize(renderMs),
				raw = {
					resultMs = resultMs,
					heartbeatMs = heartbeatMs,
					renderMs = renderMs,
					heapKiB = heapKiB,
				},
			})
		elseif message.kind == "Retire" then
			waitFor(function(): boolean
				return #Registry.GetAllActorViews() == 0
			end)

			Client._ResetForTests()
			assert(domainConnection ~= nil and tagConnection ~= nil, "Missing native consumers")
			domainConnection:Disconnect()
			tagConnection:Disconnect()
			resultConnection:Disconnect()
			uncertaintyConnection:Disconnect()
			heartbeat:Disconnect()
			render:Disconnect()
			report("Retired")
		else
			error("Unknown native command phase")
		end
	end)
end)

guard(function()
	local initialized, failure = Client.Init()
	assert(initialized, if failure ~= nil then failure.reason else "Native client startup failed")
	report("Ready")
end)
