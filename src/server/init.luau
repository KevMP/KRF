--!strict
local ServerStartTypes = require(script.types)
local ControllerTypes = require(script.Controller.types)
local TagTypes = require(script.Tags.types)
local ResourceTypes = require(script.Resource.types)
local ActionTypes = require(script.Action.types)
local ReplicationTypes = require(script.Replication.types)

local ControllerRegistry = require(script.Controller.ControllerRegistry)
local TagRegistry = require(script.Tags.TagRegistry)
local TagValidator = require(script.Tags.TagValidator)
local ResourceRegistry = require(script.Resource.ResourceRegistry)
local ActionRegistry = require(script.Action.ActionRegistry)
local ReplicationDomainRegistry = require(script.Replication.ReplicationDomainRegistry)
local BuiltInReplicationDomains = require(script.Replication.BuiltInReplicationDomains)
local SchemaCollectionUtils = require(script.Parent.shared.Networking.utils.SchemaCollectionUtils)
local ResourceValidator = require(script.Resource.utils.ResourceValidator)
local ResourceDefinitionNormalizer = require(script.Resource.utils.ResourceDefinitionNormalizer)
local PropertyController = require(script.Property.PropertyController)
local TagController = require(script.Tags.TagController)
local ResourceController = require(script.Resource.ResourceController)
local ActionController = require(script.Action.ActionController)

export type ServerStartConfig = ServerStartTypes.ServerStartConfig
export type StartupFailure = ServerStartTypes.StartupFailure

type ControllerDef = ControllerTypes.ControllerDef
type TagDefinition = TagTypes.TagDefinition
type ResourceDefinition = ResourceTypes.ResourceDefinition
type ActionFactory = ActionTypes.ActionFactory
type PreparedActionCatalog = ActionTypes.PreparedActionCatalog
type ReplicationDomainDefinition = ReplicationTypes.ReplicationDomainDefinition
type PreparedReplicationDomainCatalog = ReplicationTypes.PreparedReplicationDomainCatalog

local Server = {}
local initAttempted: boolean = false
local initialized: boolean = false

local function copyTagDefinition(definition: TagDefinition): TagDefinition
	local owned: TagDefinition = table.clone(definition)
	if definition.properties ~= nil then
		local properties: { [string]: TagTypes.PropertyModifier } = {}
		for propertyName: string, modifier: TagTypes.PropertyModifier in next, definition.properties do
			properties[propertyName] = table.freeze(table.clone(modifier)) :: TagTypes.PropertyModifier
		end
		owned.properties = table.freeze(properties)
	end
	return table.freeze(owned) :: TagDefinition
end

function Server._IsInitialized(): boolean
	return initialized
end

function Server.Init(config: ServerStartConfig): (boolean, StartupFailure?)
	if initAttempted then
		return false, { system = "Server", reason = "ServerInitAlreadyAttempted" }
	end
	initAttempted = true

	if
		ControllerRegistry.IsLoaded()
		or TagRegistry.IsLoaded()
		or ResourceRegistry.IsLoaded()
		or ActionRegistry.IsLoaded()
		or ReplicationDomainRegistry.IsLoaded()
	then
		return false, { system = "Server", reason = "CatalogAlreadyLoaded" }
	end

	local controllers: { ControllerDef } = {
		{ key = "TagController", factory = TagController.new },
		{ key = "PropertyController", factory = PropertyController.new, dependsOn = { "TagController" } },
		{ key = "ResourceController", factory = ResourceController.new, dependsOn = { "PropertyController" } },
		{ key = "ActionController", factory = ActionController.new },
	}
	local gameControllers: { ControllerDef } = config.controllers or {}
	for _, definition: ControllerDef in gameControllers do
		table.insert(controllers, definition)
	end
	local tags: { TagDefinition } = config.tags or {}
	local resources: { ResourceDefinition } = config.resources or {}
	local actions: { ActionFactory } = if config.actions ~= nil then config.actions else {}

	-- Own validated supporting definitions before Action factories run consumer
	-- code. Later Load calls cannot observe mutation of the source catalogs.
	local stagedTags: { [string]: TagDefinition } = {}
	local preparedTagIds: { [string]: boolean } = {}
	local preparedTags: { TagDefinition } = {}
	for _, definition: TagDefinition in tags do
		local valid: boolean, reason: string? = TagValidator.ValidateTagDefinition(definition, stagedTags)
		if not valid then
			return false, { system = "Tag", reason = reason :: string }
		end
		stagedTags[definition.id] = definition
		preparedTagIds[definition.id] = true
		table.insert(preparedTags, copyTagDefinition(definition))
	end

	local stagedResources: { [string]: ResourceDefinition } = {}
	local preparedResourceIds: { [string]: boolean } = {}
	local preparedResources: { ResourceTypes.LoadedResourceDefinition } = {}
	for _, definition: ResourceDefinition in resources do
		local valid: boolean, reason: string? =
			ResourceValidator.ValidateResourceDefinition(definition, stagedResources)
		if not valid then
			return false, { system = "Resource", reason = reason :: string }
		end
		stagedResources[definition.id] = definition
		preparedResourceIds[definition.id] = true
		table.insert(preparedResources, ResourceDefinitionNormalizer.NormalizeResourceDefinition(definition))
	end

	local preparedActions: PreparedActionCatalog?, actionReason: string? =
		ActionRegistry.Prepare(actions, preparedTagIds, preparedResourceIds)
	if preparedActions == nil then
		return false, { system = "Action", reason = actionReason :: string }
	end

	local gameDomains: { ReplicationDomainDefinition } = if config.replicationDomains ~= nil
		then config.replicationDomains
		else {}
	if type(gameDomains) ~= "table" then
		return false, { system = "ReplicationDomain", reason = "ReplicationDomainDefinitionsMustBeTable" }
	end
	local domainCount: number? = SchemaCollectionUtils.GetArrayLength(gameDomains)
	if domainCount == nil then
		return false, { system = "ReplicationDomain", reason = "ReplicationDomainDefinitionsMustBeArray" }
	end
	local buildCatalogs: ReplicationTypes.ReplicationDomainBuildCatalogs = {
		tags = table.freeze(preparedTags),
		resources = table.freeze(preparedResources),
		actions = preparedActions.orderedDefinitions,
	}
	table.freeze(buildCatalogs)
	local builtInDomains: { ReplicationDomainDefinition }?, buildReason: string? =
		BuiltInReplicationDomains.Build(buildCatalogs)
	if builtInDomains == nil then
		return false, { system = "ReplicationDomain", reason = buildReason or "ReplicationDomainBuildFailed" }
	end
	if type(builtInDomains) ~= "table" then
		return false, { system = "ReplicationDomain", reason = "ReplicationDomainDefinitionsMustBeTable" }
	end
	local builtInCount: number? = SchemaCollectionUtils.GetArrayLength(builtInDomains)
	if builtInCount == nil then
		return false, { system = "ReplicationDomain", reason = "ReplicationDomainDefinitionsMustBeArray" }
	end
	local domains: { ReplicationDomainDefinition } = {}
	for index: number = 1, builtInCount do
		table.insert(domains, rawget(builtInDomains, index) :: ReplicationDomainDefinition)
	end
	for index: number = 1, domainCount do
		table.insert(domains, rawget(gameDomains, index) :: ReplicationDomainDefinition)
	end
	local preparedDomains: PreparedReplicationDomainCatalog?, domainReason: string? =
		ReplicationDomainRegistry.Prepare(domains)
	if preparedDomains == nil then
		return false, { system = "ReplicationDomain", reason = domainReason :: string }
	end

	local loaded: boolean, reason: string? = ControllerRegistry.Load(controllers)
	if not loaded then
		return false, { system = "Controller", reason = reason :: string }
	end

	loaded, reason = TagRegistry.Load(preparedTags)
	if not loaded then
		return false, { system = "Tag", reason = reason :: string }
	end

	loaded, reason = ResourceRegistry.Load(preparedResources :: { ResourceDefinition })
	if not loaded then
		return false, { system = "Resource", reason = reason :: string }
	end

	loaded, reason = ActionRegistry.Publish(preparedActions :: PreparedActionCatalog)
	if not loaded then
		return false, { system = "Action", reason = reason :: string }
	end

	loaded, reason = ReplicationDomainRegistry.Publish(preparedDomains :: PreparedReplicationDomainCatalog)
	if not loaded then
		return false, { system = "ReplicationDomain", reason = reason :: string }
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
	ActionRegistry._resetForTests()
	ReplicationDomainRegistry._resetForTests()
end

return Server
