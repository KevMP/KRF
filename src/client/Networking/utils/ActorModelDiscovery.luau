--!strict
local Types = require(script.Parent.Parent.types)
local CollectionService = game:GetService("CollectionService")
local Identity = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorModelIdentity)

local ActorModelDiscovery = {} :: Types.ActorModelDiscoveryModule

function ActorModelDiscovery.new(root: Instance?): Types.ActorModelDiscoveryAdapter
	local scope: Instance = root or workspace
	local candidates: { [Instance]: Types.ActorModelCandidate } = {}
	local watched: { [Instance]: { RBXScriptConnection } } = {}
	local added: { (Types.ActorModelCandidate) -> () } = {}
	local removed: { (Instance) -> () } = {}
	local connections: { RBXScriptConnection } = {}
	local destroyed: boolean = false
	local function drop(marker: Instance): ()
		if candidates[marker] == nil then
			return
		end
		candidates[marker] = nil
		for _, callback in table.clone(removed) do
			callback(marker)
		end
	end
	local function reconcile(marker: Instance): ()
		local id: string? = Identity.GetActorId(marker)
		local model: Instance? = marker.Parent
		if id == nil or model == nil or not model:IsA("Model") or not marker:IsDescendantOf(scope) then
			drop(marker)
			return
		end
		local current: Types.ActorModelCandidate? = candidates[marker]
		if current ~= nil and current.actorId == id and current.model == model then
			return
		end
		drop(marker)
		local candidate: Types.ActorModelCandidate = { marker = marker, actorId = id, model = model }
		candidates[marker] = candidate
		for _, callback in table.clone(added) do
			callback(candidate)
		end
	end
	local function watch(marker: Instance): ()
		local listeners: { RBXScriptConnection } =
			{ marker.AncestryChanged:Connect(function()
				reconcile(marker)
			end) }
		table.insert(
			listeners,
			marker:GetPropertyChangedSignal("Name"):Connect(function()
				reconcile(marker)
			end)
		)
		if marker:IsA("StringValue") then
			table.insert(
				listeners,
				marker:GetPropertyChangedSignal("Value"):Connect(function()
					reconcile(marker)
				end)
			)
		end
		watched[marker] = listeners
		reconcile(marker)
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal(Identity.TAG):Connect(watch))
	table.insert(
		connections,
		CollectionService:GetInstanceRemovedSignal(Identity.TAG):Connect(function(marker: Instance)
			drop(marker)
			local listeners: { RBXScriptConnection }? = watched[marker]
			if listeners ~= nil then
				for _, listener in listeners do
					listener:Disconnect()
				end
				watched[marker] = nil
			end
		end)
	)
	for _, marker: Instance in CollectionService:GetTagged(Identity.TAG) do
		watch(marker)
	end
	local function observe<T>(callbacks: { T }, callback: T): () -> ()
		if not destroyed then
			table.insert(callbacks, callback)
		end
		return function()
			local index: number? = table.find(callbacks, callback)
			if index ~= nil then
				table.remove(callbacks, index)
			end
		end
	end
	return {
		GetCandidates = function(): { Types.ActorModelCandidate }
			local result: { Types.ActorModelCandidate } = {}
			for _, candidate in candidates do
				table.insert(result, candidate)
			end
			return result
		end,
		ObserveAdded = function(callback: (Types.ActorModelCandidate) -> ()): () -> ()
			return observe(added, callback)
		end,
		ObserveRemoved = function(callback: (Instance) -> ()): () -> ()
			return observe(removed, callback)
		end,
		Destroy = function(): ()
			if destroyed then
				return
			end
			destroyed = true
			for _, connection in connections do
				connection:Disconnect()
			end
			for _, listeners in watched do
				for _, listener in listeners do
					listener:Disconnect()
				end
			end
			table.clear(watched)
			table.clear(candidates)
			table.clear(added)
			table.clear(removed)
		end,
	}
end

return ActorModelDiscovery
