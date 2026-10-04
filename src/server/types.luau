--!strict
local serverFolder = script.Parent

local ControllerTypes = require(serverFolder.Controller.types)
local TagTypes = require(serverFolder.Tags.types)
local ResourceTypes = require(serverFolder.Resource.types)
local ActionTypes = require(serverFolder.Action.types)

local types = {}

export type ServerStartConfig = {
	controllers: { ControllerTypes.ControllerDef }?,
	tags: { TagTypes.TagDefinition }?,
	resources: { ResourceTypes.ResourceDefinition }?,
	actions: { ActionTypes.ActionFactory }?,
}

export type StartupFailure = {
	system: string,
	reason: string,
}

return types
