--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local PlayerActors = {}

local actors: { [Player]: KRF.Actor } = {}

local function register(player: Player, character: Model): ()
	local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(character)

	if actor == nil then
		warn(`Could not register {player.Name}'s character as an Actor: {reason}`)
		return
	end

	actors[player] = actor
end

local function unregister(player: Player): ()
	local actor: KRF.Actor? = actors[player]
	actors[player] = nil

	if actor ~= nil then
		KRF.ActorRuntime.UnregisterActor(actor, "CharacterRemoving")
	end
end

local function track(player: Player): ()
	player.CharacterAdded:Connect(function(character: Model)
		register(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		unregister(player)
	end)

	if player.Character ~= nil then
		register(player, player.Character)
	end
end

function PlayerActors.Start(): ()
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(unregister)

	for _, player: Player in Players:GetPlayers() do
		track(player)
	end
end

function PlayerActors.GetActor(player: Player): KRF.Actor?
	local actor: KRF.Actor? = actors[player]

	return if actor ~= nil and actor.enabled then actor else nil
end

return PlayerActors
