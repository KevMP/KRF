--!strict
local ServerStartTypes = require(script.types)
local ControllerTypes = require(script.Controller.types)
local TagTypes = require(script.Tags.types)
local ResourceTypes = require(script.Resource.types)

local ControllerRegistry = require(script.Controller.ControllerRegistry)
local TagRegistry = require(script.Tags.TagRegistry)
local TagValidator = require(script.Tags.TagValidator)
local ResourceRegistry = require(script.Resource.ResourceRegistry)
local ResourceValidator = require(script.Resource.utils.ResourceValidator)

export type ServerStartConfig = ServerStartTypes.ServerStartConfig
export type StartupFailure = ServerStartTypes.StartupFailure

type ControllerDef = ControllerTypes.ControllerDef
type TagDefinition = TagTypes.TagDefinition
type ResourceDefinition = ResourceTypes.ResourceDefinition

local Server = {}
local initAttempted: boolean = false

function Server.Init(config: ServerStartConfig): (boolean, StartupFailure?)
	if initAttempted then
		return false, { system = "Server", reason = "ServerInitAlreadyAttempted" }
	end
	initAttempted = true

	if ControllerRegistry.IsLoaded() or TagRegistry.IsLoaded() or ResourceRegistry.IsLoaded() then
		return false, { system = "Server", reason = "CatalogAlreadyLoaded" }
	end

	local controllers: { ControllerDef } = config.controllers or {}
	local tags: { TagDefinition } = config.tags or {}
	local resources: { ResourceDefinition } = config.resources or {}

	-- Validate the other catalogs before publishing any of them. Their Load calls
	-- run the same validators and do not yield, so publication cannot fail later.
	local stagedTags: { [string]: TagDefinition } = {}
	for _, definition: TagDefinition in tags do
		local valid: boolean, reason: string? = TagValidator.ValidateTagDefinition(definition, stagedTags)
		if not valid then
			return false, { system = "Tag", reason = reason :: string }
		end
		stagedTags[definition.id] = definition
	end

	local stagedResources: { [string]: ResourceDefinition } = {}
	for _, definition: ResourceDefinition in resources do
		local valid: boolean, reason: string? =
			ResourceValidator.ValidateResourceDefinition(definition, stagedResources)
		if not valid then
			return false, { system = "Resource", reason = reason :: string }
		end
		stagedResources[definition.id] = definition
	end

	local loaded: boolean, reason: string? = ControllerRegistry.Load(controllers)
	if not loaded then
		return false, { system = "Controller", reason = reason :: string }
	end

	loaded, reason = TagRegistry.Load(tags)
	if not loaded then
		return false, { system = "Tag", reason = reason :: string }
	end

	loaded, reason = ResourceRegistry.Load(resources)
	if not loaded then
		return false, { system = "Resource", reason = reason :: string }
	end

	return true, nil
end

function Server._ResetForTests(): ()
	initAttempted = false
	ControllerRegistry._ResetForTests()
	TagRegistry._resetForTests()
	ResourceRegistry._resetForTests()
end

return Server
