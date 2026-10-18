--!strict
local CollectionService = game:GetService("CollectionService")

local ActorModelIdentity = { NAME = "__KRFActor", TAG = "KRF.ActorModel" }

function ActorModelIdentity.GetActorId(marker: Instance): string?
	if not marker:IsA("StringValue") then
		return nil
	end

	local tagged: boolean = CollectionService:HasTag(marker, ActorModelIdentity.TAG)

	if marker.Name ~= ActorModelIdentity.NAME or not tagged or marker.Value == "" then
		return nil
	end

	return marker.Value
end

function ActorModelIdentity.GetMarker(model: Model): Instance?
	local marker: Instance? = model:FindFirstChild(ActorModelIdentity.NAME)

	return if marker ~= nil and ActorModelIdentity.GetActorId(marker) ~= nil then marker else nil
end

return table.freeze(ActorModelIdentity)
