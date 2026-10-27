--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local Client = require(KRF.client)
local Registry = require(KRF.client.Actor.ActorViewRegistry)
local State = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local Soak = require(ReplicatedStorage.NetworkingSoak)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingBaselineControl") :: RemoteEvent
local observers: { [string]: any } = {}
local events, added, removed = 0, 0, 0
local failed = false

local function report(message: any): ()
	control:FireServer(buffer.fromstring(HttpService:JSONEncode(message)))
end

local function guard(callback: () -> ()): ()
	if failed then
		return
	end

	local ok, reason = pcall(callback)

	if not ok then
		failed = true
		report({ kind = "Failed", failure = tostring(reason) })
	end
end

local onAdded = Registry.OnActorViewAdded:Connect(function(view)
	guard(function()
		local id = view:GetId()
		assert(observers[id] == nil, "Duplicate ActorView")

		observers[id] = view:GetTags().OnTagRefreshed:Connect(function(tagId: string)
			guard(function()
				assert(tagId == "Soak.Pulse", "Unexpected semantic event")
				events += 1
			end)
		end)

		added += 1
	end)
end)

local onRemoving = Registry.OnActorViewRemoving:Connect(function(view)
	guard(function()
		local id = view:GetId()
		assert(observers[id] ~= nil, "Unknown retiring ActorView")
		observers[id]:Disconnect()
		observers[id] = nil
		removed += 1
	end)
end)

control.OnClientEvent:Connect(function(payload: buffer)
	guard(function()
		local message = HttpService:JSONDecode(buffer.tostring(payload))
		local owner = State.Get()
		assert(owner ~= nil, "Missing installed client diagnostics")

		if message.quiet then
			local deadline = os.clock() + 25

			while true do
				local correct = #Registry.GetAllActorViews() == #message.expected and events == message.events

				for _, expected in message.expected do
					local view = Registry.GetActorViewById(expected.id)
					local domain = if view ~= nil then view:GetDomain("KRF.Tags") else nil
					local state: any = if domain ~= nil then domain:GetState() else nil
					local tag = if state ~= nil then state["Soak.Pulse"] else nil
					correct = correct and tag ~= nil and math.abs(tag.expiresAt - expected.expiresAt) < 0.00001
				end

				if correct then
					break
				end

				assert(os.clock() < deadline, "Quiet delivery/lifecycle mismatch")
				task.wait(0.05)
			end

			Soak.assertDrained(owner:Snapshot(), false)
		end

		if message.kind == "Destroy" then
			assert(#Registry.GetAllActorViews() == 0 and next(observers) == nil, "Retained views/observers")
			onAdded:Disconnect()
			onRemoving:Disconnect()
			Client._ResetForTests()
			assert(State.Get() == nil, "Client Networking survived teardown")
			Soak.assertDrained(owner:Snapshot(), true)
		end

		local sample = Soak.read(owner)
		sample.kind, sample.sequence = message.kind, message.sequence
		sample.actorViews, sample.events = #Registry.GetAllActorViews(), events
		sample.added, sample.removed = added, removed
		report(sample)
	end)
end)

guard(function()
	assert(Client.Init(), "Client startup failed")
	report({ kind = "Ready" })
end)
