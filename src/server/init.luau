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
local PropertyController = require(script.Property.PropertyController)
local TagController = require(script.Tags.TagController)
local ResourceController = require(script.Resource.ResourceController)

export type ServerStartConfig = ServerStartTypes.ServerStartConfig
export type StartupFailure = ServerStartTypes.StartupFailure

type ControllerDef = ControllerTypes.ControllerDef
type TagDefinition = TagTypes.TagDefinition
type ResourceDefinition = ResourceTypes.ResourceDefinition

local Server = {}
local initAttempted: boolean = false
local initialized: boolean = false

function Server._IsInitialized(): boolean
	return initialized
end

function Server.Init(config: ServerStartConfig): (boolean, StartupFailure?)
	if initAttempted then
		return false, { system = "Server", reason = "ServerInitAlreadyAttempted" }
	end
	initAttempted = true

	if ControllerRegistry.IsLoaded() or TagRegistry.IsLoaded() or ResourceRegistry.IsLoaded() then
		return false, { system = "Server", reason = "CatalogAlreadyLoaded" }
	end

	local controllers: { ControllerDef } = {
		{ key = "TagController", factory = TagController.new },
		{ key = "PropertyController", factory = PropertyController.new, dependsOn = { "TagController" } },
		{ key = "ResourceController", factory = ResourceController.new, dependsOn = { "PropertyController" } },
	}
	local gameControllers: { ControllerDef } = config.controllers or {}
	for _, definition: ControllerDef in gameControllers do
		table.insert(controllers, definition)
	end
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

	initialized = true
	return true, nil
end

function Server._ResetForTests(): ()
	initAttempted = false
	initialized = false
	ControllerRegistry._ResetForTests()
	TagRegistry._resetForTests()
	ResourceRegistry._resetForTests()
end

return Server
