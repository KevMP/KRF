--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local PlayerActors = {}

function register(player: Player, character: Model): ()
	local actor: KRF.Actor?, reason: string? = KRF.ActorRuntime.RegisterActor(character)

	if actor == nil then
		warn(`Could not register {player.Name}'s character as an Actor: {reason}`)
	end
end

function unregister(character: Model): ()
	local actor: KRF.Actor? = KRF.ActorRegistry.GetActorByModel(character)

	if actor ~= nil then
		KRF.ActorRuntime.UnregisterActor(actor, "CharacterRemoving")
	end
end

function track(player: Player): ()
	player.CharacterAdded:Connect(function(character: Model)
		register(player, character)
	end)
	player.CharacterRemoving:Connect(unregister)

	if player.Character ~= nil then
		register(player, player.Character)
	end
end

function PlayerActors.Start(): ()
	Players.PlayerAdded:Connect(track)

	for _, player: Player in Players:GetPlayers() do
		track(player)
	end
end

return PlayerActors
