--!strict
local ActionTypes = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local TagTypes = require(script.Parent.Parent.Parent.Tags.types)

type Actor = ActorTypes.Actor
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type TagController = TagTypes.TagController

local ActionControllerTagRequirements = {}

function ActionControllerTagRequirements.Validate(actor: Actor, definition: LoadedActionDefinition): string?
	local tags: TagController? = actor:GetController("TagController") :: TagController?
	for _, tagId: string in definition.requiredTags do
		if tags == nil or not tags:HasTag(tagId) then
			return "ActionRequiredTagMissing:" .. tagId
		end
	end
	if tags ~= nil then
		for _, tagId: string in definition.blockedTags do
			if tags:HasTag(tagId) then
				return "ActionBlockedTagPresent:" .. tagId
			end
		end
	end
	return nil
end

return ActionControllerTagRequirements
