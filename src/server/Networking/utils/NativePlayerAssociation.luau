--!strict
local Types = require(script.Parent.Parent.types)
local Players = game:GetService("Players")

local NativePlayerAssociation = {} :: Types.PlayerAssociationModule

function NativePlayerAssociation.new(players: Players?): Types.PlayerAssociationSource
	local service: Players = players or Players
	local characters: { [Player]: Model } = {}
	local owners: { [Model]: Player } = {}
	local listeners: { [Player]: RBXScriptConnection } = {}
	local callbacks: { (Model) -> () } = {}
	local destroyed: boolean = false
	local function notify(model: Model?): ()
		if model == nil then
			return
		end
		for _, callback in table.clone(callbacks) do
			callback(model)
		end
	end
	local function changed(player: Player): ()
		if destroyed then
			return
		end
		local previous: Model? = characters[player]
		local current: Model? = player.Character
		if previous == current then
			return
		end
		if previous ~= nil and owners[previous] == player then
			owners[previous] = nil
		end
		characters[player] = current
		if current ~= nil then
			owners[current] = player
		end
		notify(previous)
		notify(current)
	end
	local function add(player: Player): ()
		if destroyed or listeners[player] ~= nil then
			return
		end
		listeners[player] = player:GetPropertyChangedSignal("Character"):Connect(function()
			changed(player)
		end)
		changed(player)
	end
	local added: RBXScriptConnection = service.PlayerAdded:Connect(add)
	local removed: RBXScriptConnection = service.PlayerRemoving:Connect(function(player: Player)
		local listener: RBXScriptConnection? = listeners[player]
		if listener ~= nil then
			listener:Disconnect()
			listeners[player] = nil
		end
		local previous: Model? = characters[player]
		characters[player] = nil
		if previous ~= nil and owners[previous] == player then
			owners[previous] = nil
		end
		notify(previous)
	end)
	for _, player: Player in service:GetPlayers() do
		add(player)
	end
	return {
		GetPlayerFromCharacter = function(model: Model): Player?
			return owners[model]
		end,
		ObserveAssociationChanged = function(callback: (Model) -> ()): () -> ()
			if not destroyed then
				table.insert(callbacks, callback)
			end
			return function()
				local index: number? = table.find(callbacks, callback)
				if index ~= nil then
					table.remove(callbacks, index)
				end
			end
		end,
		Destroy = function(): ()
			if destroyed then
				return
			end
			destroyed = true
			added:Disconnect()
			removed:Disconnect()
			for _, listener in listeners do
				listener:Disconnect()
			end
			table.clear(listeners)
			table.clear(characters)
			table.clear(owners)
			table.clear(callbacks)
		end,
	}
end

return NativePlayerAssociation
