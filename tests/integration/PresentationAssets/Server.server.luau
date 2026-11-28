--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Workspace = game:GetService("Workspace")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local Networking = require(KRF.server.Networking.ServerNetworking)

local control: RemoteEvent = ReplicatedStorage:WaitForChild("AssetsControl") :: RemoteEvent
local CLIENT_COUNT: number = 2

local initialized, failure = Server.Init({
	actions = {
		function(): ActionTypes.ActionDefinition
			return { id = "Cast", visibility = "ClientVisible", autoGrant = true }
		end,
	},
})

assert(initialized, if failure ~= nil then failure.reason else "Server.Init failed")

local baseplate: Part = Instance.new("Part")
baseplate.Name = "Baseplate"
baseplate.Anchored = true
baseplate.Size = Vector3.new(512, 4, 512)
baseplate.Position = Vector3.new(0, -2, 0)
baseplate.Parent = Workspace

local model: Model = Instance.new("Model")
model.Name = "Caster"

local root: Part = Instance.new("Part")
root.Anchored = true
root.Position = Vector3.new(0, 5, 20)
root.Parent = model
model.PrimaryPart = root
model.Parent = Workspace

local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
assert(actor ~= nil, reason)

local controller: ActionTypes.ActionController = actor:GetController("ActionController") :: ActionTypes.ActionController
local passed: { [Player]: string } = {}
local finished: boolean = false

local function finish(success: boolean, detail: string?): ()
	if finished then
		return
	end

	local observed: { [string]: string } = {}

	for player: Player, statuses: string in passed do
		observed[player.Name] = statuses
	end

	finished = true
	Networking.Destroy()
	model:Destroy()
	StudioTestService:EndTest({ success = success, reason = detail, observed = observed })
end

control.OnServerEvent:Connect(function(player: Player, message: unknown, detail: unknown)
	if finished then
		return
	end

	if message == "Cast" then
		if not controller:RequestAction("Cast").accepted then
			finish(false, `{player.Name}: Cast was refused`)
		end

		return
	elseif message ~= "Pass" then
		finish(false, `{player.Name}: {tostring(detail)}`)

		return
	end

	passed[player] = tostring(detail)

	local count: number = 0

	for _ in passed do
		count += 1
	end

	if count >= CLIENT_COUNT then
		finish(true, nil)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	if not passed[player] then
		finish(false, `{player.Name} left before reporting`)
	end
end)

task.delay(110, function()
	finish(false, "Assets native fixture timed out")
end)
