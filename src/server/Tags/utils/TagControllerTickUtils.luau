--!strict
local serverFolder = script.Parent.Parent.Parent

local ActorTypes = require(serverFolder.Actor.types)
local TagTypes = require(serverFolder.Tags.types)

type Actor = ActorTypes.Actor
type TagDefinition = TagTypes.TagDefinition

local TagControllerTickUtils = {}

function TagControllerTickUtils.FireProtectedOnTick(tagDefinition: TagDefinition, actor: Actor, deltaTime: number): ()
	if tagDefinition.onTick == nil then
		return
	end

	local succeeded: boolean, failureReason: unknown? = pcall(tagDefinition.onTick, actor, deltaTime)

	if not succeeded then
		warn(("[TagController] onTick failed tagId=%s err=%s"):format(tagDefinition.id, tostring(failureReason)))
	end
end

return TagControllerTickUtils
