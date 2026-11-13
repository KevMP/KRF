--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Schemas = require(ReplicatedStorage.FireDemoShared.RequestSchemas)
local Arena = require(script.Parent.Arena)
local Actions = require(script.Parent.ActionCatalog)
local Tags = require(script.Parent.TagCatalog)

local dummyModel: Model, effects: Folder = Arena.Build()
local dummy: ActorTypes.Actor? = nil
local owned: { [Player]: ActorTypes.Actor } = {}
local grants: { string } = { "Demo.FireBreath", "Demo.Fireball", "Demo.FlameStrike" }

local started: boolean, failure = Server.Init({
	tags = Tags,
	actions = Actions.Create(function(): ActorTypes.Actor?
		return dummy
	end, effects),
	actionRequestSchemas = Schemas,
})

assert(started, if failure ~= nil then failure.system .. ":" .. failure.reason else "ServerStartupFailed")
dummy = assert(Actors.RegisterActor(dummyModel))

local function remove(player: Player): ()
	local actor: ActorTypes.Actor? = owned[player]

	owned[player] = nil

	if actor ~= nil then
		Actors.UnregisterActor(actor)
	end
end

local function characterAdded(player: Player, character: Model): ()
	local previous: ActorTypes.Actor? = owned[player]

	if player.Character ~= character or (previous ~= nil and previous.model == character) then
		return
	end

	remove(player)
	local actor: ActorTypes.Actor = assert(Actors.RegisterActor(character))

	owned[player] = actor

	local actions: ActionTypes.ActionController =
		assert(actor:GetController("ActionController")) :: ActionTypes.ActionController

	assert(actions:SetGrants("Demo.Loadout", grants))

	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent): ()
		print("[FireDemo server] Started", event.actionId, event.sequenceId)
	end)

	actions.OnActionEnded:Connect(function(event: ActionTypes.ActionLifecycleEvent): ()
		print("[FireDemo server] Ended", event.actionId, event.sequenceId)
	end)

	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent): ()
		print("[FireDemo server] Interrupted", event.actionId, event.sequenceId, event.reason)
	end)

	print("[FireDemo server] Character Actor registered", player.Name, actor:GetId())

	-- Character registration is immediate; rig loading only gates this demo's placement.
	local root: Instance? = character:WaitForChild("HumanoidRootPart", 10)

	if root ~= nil and player.Character == character and owned[player] == actor then
		character:PivotTo(CFrame.lookAt(Vector3.new(0, 4, 12), Vector3.new(0, 4, -12)))
	end
end

local function playerAdded(player: Player): ()
	player.CharacterAdded:Connect(function(character: Model): ()
		characterAdded(player, character)
	end)

	player.CharacterRemoving:Connect(function(character: Model): ()
		local actor: ActorTypes.Actor? = owned[player]

		if actor ~= nil and actor.model == character then
			remove(player)
		end
	end)

	if player.Character ~= nil then
		task.spawn(characterAdded, player, player.Character)
	end
end

Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(remove)

for _, player: Player in Players:GetPlayers() do
	playerAdded(player)
end

print("[FireDemo server] Ready. Press Play with a client, then use F, Q, X-Q-Z.")
