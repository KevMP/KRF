--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionRouteControl") :: RemoteEvent
local subjects: Folder = ReplicatedStorage:WaitForChild("ActionRouteSubjects") :: Folder
local manual: boolean = ReplicatedStorage:FindFirstChild("ActionRouteManual") ~= nil
local actors: { ActorTypes.Actor } = {}
local models: { Model } = {}
local connections: { SignalTypes.Connection } = {}
local ready: { [Player]: boolean } = {}
local done: { [Player]: boolean } = {}
local measurements: { any } = {}
local serverStarts: number = 0
local finished: boolean = false

Players.CharacterAutoLoads = false

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, actor: ActorTypes.Actor in actors do
		Actors.UnregisterActor(actor)
	end

	Networking.Destroy()

	for _, model: Model in models do
		model:Destroy()
	end

	StudioTestService:EndTest({
		success = success,
		reason = reason,
		serverStarts = serverStarts,
		measurements = measurements,
	})
end

if not manual then
	control.OnServerEvent:Connect(function(player: Player, phase: any, payload: any): ()
		if finished then
			return
		end

		if phase == "Failure" then
			finish(false, tostring(payload))

			return
		end

		if phase == "ReadyForRemoval" and not ready[player] then
			ready[player] = true

			if #Players:GetPlayers() == 2 then
				for _, peer: Player in Players:GetPlayers() do
					if not ready[peer] then
						return
					end
				end

				assert(Actors.UnregisterActor(actors[1]), "NativeActorRemovalFailed")
			end
		elseif phase == "Done" and ready[player] and not done[player] then
			done[player] = true
			table.insert(measurements, payload)

			for _, peer: Player in Players:GetPlayers() do
				if not done[peer] then
					return
				end
			end

			for _, descendant: Instance in game:GetDescendants() do
				if
					descendant:IsA("InputContext")
					and descendant.Parent ~= nil
					and descendant.Parent.Name == "KRFInputs"
				then
					finish(false, "ClientInputsReplicatedToServer")

					return
				end
			end

			finish(serverStarts == 0, if serverStarts == 0 then nil else "I4StartedServerAction")
		end
	end)

	task.delay(60, function(): ()
		finish(false, "NativeActionRouteTimeout")
	end)
end

local initialized: boolean, failure = Server.Init({})
assert(initialized, if failure ~= nil then failure.reason else "NativeServerInitFailed")

for index: number = 1, 2 do
	local model: Model = Instance.new("Model")
	model.Name = "ActionRouteSubject" .. index

	local root: Part = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CFrame = CFrame.new(index * 5, 0, 0)
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor = assert(Actors.RegisterActor(model))
	table.insert(actors, actor)
	subjects:SetAttribute("Actor" .. index, actor:GetId())

	local actions: ActionTypes.ActionController =
		actor:GetController("ActionController") :: ActionTypes.ActionController

	table.insert(
		connections,
		actions.OnActionStarted:Connect(function()
			serverStarts += 1
		end)
	)
end
