--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local CollectionService = game:GetService("CollectionService")
local Identity = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorModelIdentity)

local ActorModelMarker = {} :: Types.ActorModelMarkerModule

local owned: { [ActorTypes.Actor]: { marker: StringValue, connection: RBXScriptConnection } } = {}

function ActorModelMarker.Install(actor: ActorTypes.Actor): (boolean, string?)
	local model: Model? = actor.model

	if model == nil then
		return false, "ActorModelMissing"
	end

	local current = owned[actor]

	if current ~= nil and current.marker.Parent == model then
		return true, nil
	end

	if model:FindFirstChild(Identity.NAME) ~= nil then
		return false, "ActorModelMarkerConflict"
	end

	local marker: StringValue = Instance.new("StringValue")
	marker.Name = Identity.NAME
	marker.Value = actor:GetId()
	marker.Archivable = false
	CollectionService:AddTag(marker, Identity.TAG)

	local connection: RBXScriptConnection = marker.Destroying:Connect(function()
		local ownership = owned[actor]

		if ownership ~= nil then
			ownership.connection:Disconnect()
			owned[actor] = nil
		end
	end)

	owned[actor] = { marker = marker, connection = connection }
	marker.Parent = model

	return true, nil
end

function ActorModelMarker.Remove(actor: ActorTypes.Actor): ()
	local ownership = owned[actor]

	if ownership == nil then
		return
	end

	owned[actor] = nil
	ownership.connection:Disconnect()
	ownership.marker:Destroy()
end

function ActorModelMarker.GetActorId(marker: Instance): string?
	return Identity.GetActorId(marker)
end

function ActorModelMarker.GetMarker(model: Model): Instance?
	return Identity.GetMarker(model)
end

return ActorModelMarker
