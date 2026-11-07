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
local CommandRegistry = require(script.Networking.CommandRegistry)
local HintRegistry = require(script.Networking.HintRegistry)
local BuiltInReplicationDomains = require(script.Replication.BuiltInReplicationDomains)
local SchemaCollectionUtils = require(script.Parent.shared.Networking.utils.SchemaCollectionUtils)
local ResourceValidator = require(script.Resource.utils.ResourceValidator)
local ResourceDefinitionNormalizer = require(script.Resource.utils.ResourceDefinitionNormalizer)
local PropertyController = require(script.Property.PropertyController)
local TagController = require(script.Tags.TagController)
local ResourceController = require(script.Resource.ResourceController)
local ActionController = require(script.Action.ActionController)
local ServerNetworking = require(script.Networking.ServerNetworking)
local PublicationRuntime = require(script.Networking.PublicationRuntime)
local SharedNetworkingTypes = require(script.Parent.shared.Networking.types)
local NetworkingTypes = require(script.Networking.types)
local ActorTypes = require(script.Actor.types)
local ActionRequestTypes = require(script.ActionRequest.types)
local SharedActionRequestTypes = require(script.Parent.shared.ActionRequest.types)
local ActionRequestCatalog = require(script.Parent.shared.ActionRequest.ActionRequestCatalog)
local ActionRequestRuntime = require(script.ActionRequest.ActionRequestRuntime)
local ActionRequestValidator = require(script.ActionRequest.ActionRequestValidator)

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
local actionRequests: ActionRequestTypes.ServerActionRequestRuntime? = nil

local function rollbackStartup(): ()
	if actionRequests ~= nil then
		actionRequests:Destroy()
		actionRequests = nil
	end

	ServerNetworking.Destroy()
	CommandRegistry._RollbackStartup()
	HintRegistry._RollbackStartup()
	ControllerRegistry._RollbackStartup()
	TagRegistry._RollbackStartup()
	ResourceRegistry._RollbackStartup()
	ActionRegistry._RollbackStartup()
	ReplicationDomainRegistry._RollbackStartup()
end

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
		or CommandRegistry.IsLoaded()
		or HintRegistry.IsLoaded()
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

	local consumerCommands: any = if config.commands ~= nil then config.commands else {}

	local reservedValid: boolean, reservedReason: string? =
		ActionRequestValidator.ValidateReservedCommands(consumerCommands)

	if not reservedValid then
		return false, { system = "Command", reason = reservedReason :: string }
	end

	-- The shared wire catalog compiles before any consumer code runs; its runtime owns
	-- only the three fixed commands and never grants an Action.
	local requestCatalog: SharedActionRequestTypes.ActionRequestCatalog? = nil
	local requestRuntime: ActionRequestTypes.ServerActionRequestRuntime? = nil
	local commandDefinitions: any = consumerCommands

	if config.actionRequestSchemas ~= nil then
		local compiled: SharedActionRequestTypes.ActionRequestCatalog?, catalogReason: string? =
			ActionRequestCatalog.Compile(config.actionRequestSchemas)

		if compiled == nil then
			return false, { system = "ActionRequest", reason = catalogReason :: string }
		end

		local authority: any = config.actionControlAuthority

		if authority ~= nil and type(authority) ~= "function" then
			return false, { system = "ActionRequest", reason = "ActionControlAuthorityInvalid" }
		end

		requestCatalog = compiled

		local created: ActionRequestTypes.ServerActionRequestRuntime = ActionRequestRuntime.new(compiled, {
			GetActionController = function(actor: ActorTypes.Actor): ActionTypes.InternalActionController?
				return actor:GetController("ActionController") :: ActionTypes.InternalActionController?
			end,
			AuthorizeControl = authority,
		})

		-- Unpublished runtimes own no subscriptions, so an early startup failure needs no teardown.
		requestRuntime = created
		local consumerCount: number? = SchemaCollectionUtils.GetArrayLength(consumerCommands)

		-- Malformed consumer collections are passed through so CommandRegistry reports them.
		if type(consumerCommands) == "table" and consumerCount ~= nil then
			local merged: { NetworkingTypes.CommandDefinition } = {}

			for index: number = 1, consumerCount do
				table.insert(merged, rawget(consumerCommands, index) :: NetworkingTypes.CommandDefinition)
			end

			for _, definition: NetworkingTypes.CommandDefinition in created:GetCommandDefinitions() do
				table.insert(merged, definition)
			end

			commandDefinitions = merged
		end
	end

	local preparedCommands, commandReason = CommandRegistry.Prepare(commandDefinitions)

	if preparedCommands == nil then
		return false, { system = "Command", reason = commandReason :: string }
	end

	local preparedHints, hintReason = HintRegistry.Prepare(if config.hints ~= nil then config.hints else {})

	if preparedHints == nil then
		return false, { system = "Hint", reason = hintReason :: string }
	end

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

	if requestCatalog ~= nil then
		local requestsValid: boolean, requestReason: string? =
			ActionRequestValidator.ValidateCatalog(requestCatalog, preparedActions)

		if not requestsValid then
			return false, { system = "ActionRequest", reason = requestReason :: string }
		end
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
		local definition: any = rawget(gameDomains, index)

		-- Framework ids remain reserved when their visible catalogs are empty.
		if
			type(definition) == "table"
			and (
				rawget(definition, "id") == "KRF.Tags"
				or rawget(definition, "id") == "KRF.Resources"
				or rawget(definition, "id") == "KRF.Actions"
			)
		then
			return false, { system = "ReplicationDomain", reason = "DuplicateReplicationDomainId" }
		end

		table.insert(domains, definition :: ReplicationDomainDefinition)
	end

	local preparedDomains: PreparedReplicationDomainCatalog?, domainReason: string? =
		ReplicationDomainRegistry.Prepare(domains)

	if preparedDomains == nil then
		return false, { system = "ReplicationDomain", reason = domainReason :: string }
	end

	local eventsValid: boolean, eventReason: string? = PublicationRuntime.ValidateEventBounds(preparedDomains, 65536)

	if not eventsValid then
		return false, { system = "Networking", reason = eventReason :: string }
	end

	local prepared: boolean, protocol: SharedNetworkingTypes.PreparedProtocol?, networkingReason: string? =
		pcall(ServerNetworking.Prepare, preparedDomains, preparedCommands, preparedHints)

	if not prepared then
		return false, { system = "Networking", reason = "StartupInternalFailure:" .. tostring(protocol) }
	end

	if protocol == nil then
		return false, { system = "Networking", reason = networkingReason :: string }
	end

	local publicationSystem: string = "Controller"

	local published: boolean, loaded: boolean, reason: string? = pcall(function(): (boolean, string?)
		local success: boolean, failure: string? = ControllerRegistry.Load(controllers)

		if not success then
			return false, failure
		end

		publicationSystem = "Tag"
		success, failure = TagRegistry.Load(preparedTags)

		if not success then
			return false, failure
		end

		publicationSystem = "Resource"
		success, failure = ResourceRegistry.Load(preparedResources :: { ResourceDefinition })

		if not success then
			return false, failure
		end

		publicationSystem = "Action"
		success, failure = ActionRegistry.Publish(preparedActions :: PreparedActionCatalog)

		if not success then
			return false, failure
		end

		publicationSystem = "ReplicationDomain"
		success, failure = ReplicationDomainRegistry.Publish(preparedDomains :: PreparedReplicationDomainCatalog)

		if not success then
			return false, failure
		end

		publicationSystem = "Command"
		success, failure = CommandRegistry.Publish(preparedCommands)

		if not success then
			return false, failure
		end

		publicationSystem = "Hint"
		success, failure = HintRegistry.Publish(preparedHints)

		if not success then
			return false, failure
		end

		publicationSystem = "Networking"

		return ServerNetworking.Publish(protocol :: SharedNetworkingTypes.PreparedProtocol)
	end)

	actionRequests = requestRuntime

	if not published or not loaded then
		rollbackStartup()

		return false,
			{
				system = publicationSystem,
				reason = if published then reason :: string else "StartupInternalFailure:" .. tostring(loaded),
			}
	end

	initialized = true

	return true, nil
end

function Server._ResetForTests(): ()
	initAttempted = false
	initialized = false
	rollbackStartup()
end

return Server
