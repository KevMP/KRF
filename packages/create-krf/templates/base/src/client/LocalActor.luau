--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local LocalActor = {}

function LocalActor.Observe(callback: (KRF.ActorView) -> ()): ()
	local player: Player = Players.LocalPlayer
	local current: KRF.ActorView? = nil

	local function refresh(): ()
		local character: Model? = player.Character
		local view: KRF.ActorView? = if character ~= nil
			then KRF.ActorViewRegistry.GetActorViewByModel(character)
			else nil

		if view ~= nil and view ~= current then
			current = view
			callback(view)
		end
	end

	KRF.ActorViewRegistry.OnActorViewAdded:Connect(function(view: KRF.ActorView)
		view.OnModelChanged:Connect(refresh)
		refresh()
	end)
	player.CharacterAdded:Connect(refresh)
	refresh()
end

return LocalActor
