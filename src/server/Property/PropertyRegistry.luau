--!strict
local PropertyTypes = require(script.Parent.types)
local CollectionUtils = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

type PropertyDefinition = PropertyTypes.PropertyDefinition
type PreparedPropertyCatalog = PropertyTypes.PreparedPropertyCatalog

local PropertyRegistry = {}
local loaded: boolean = false
local definitionsById: { [string]: PropertyDefinition } = table.freeze({} :: { [string]: PropertyDefinition })
local orderedDefinitions: { PropertyDefinition } = table.freeze({} :: { PropertyDefinition })

local BUILT_INS: { PropertyDefinition } = table.freeze({
	table.freeze({ id = "WalkSpeed", defaultBaseValue = 16, autoAssign = true }) :: PropertyDefinition,
	table.freeze({ id = "JumpPower", defaultBaseValue = 50, autoAssign = true }) :: PropertyDefinition,
})

function PropertyRegistry.Prepare(definitions: { PropertyDefinition }): (PreparedPropertyCatalog?, string?)
	if loaded then
		return nil, "PropertyDefinitionsAlreadyLoaded"
	end

	if type(definitions) ~= "table" then
		return nil, "PropertyDefinitionsMustBeTable"
	end

	local count: number? = CollectionUtils.GetArrayLength(definitions)

	if count == nil then
		return nil, "PropertyDefinitionsMustBeArray"
	end

	local gameById: { [string]: PropertyDefinition } = {}
	local gameDefinitions: { PropertyDefinition } = {}

	for index: number = 1, count do
		local definition: any = rawget(definitions, index)

		if type(definition) ~= "table" then
			return nil, "PropertyDefinitionMustBeTable"
		end

		local id: any = rawget(definition, "id")
		local value: any = rawget(definition, "defaultBaseValue")
		local autoAssign: any = rawget(definition, "autoAssign")

		if type(id) ~= "string" or id == "" then
			return nil, "InvalidPropertyId"
		end

		if gameById[id] ~= nil then
			return nil, "PropertyIdAlreadyRegistered"
		end

		if type(value) ~= "number" or not math.isfinite(value) then
			return nil, "PropertyDefaultBaseValueMustBeFiniteNumber"
		end

		if autoAssign ~= nil and type(autoAssign) ~= "boolean" then
			return nil, "PropertyAutoAssignMustBeBoolean"
		end

		for key in next, definition do
			if key ~= "id" and key ~= "defaultBaseValue" and key ~= "autoAssign" then
				return nil, "PropertyDefinitionFieldUnsupported"
			end
		end

		local owned: PropertyDefinition = table.freeze({
			id = id,
			defaultBaseValue = value,
			autoAssign = if autoAssign ~= nil then autoAssign else id == "WalkSpeed" or id == "JumpPower",
		})

		gameById[id] = owned
		table.insert(gameDefinitions, owned)
	end

	local stagedById: { [string]: PropertyDefinition } = {}
	local stagedOrdered: { PropertyDefinition } = {}

	for _, builtIn: PropertyDefinition in BUILT_INS do
		local definition: PropertyDefinition = gameById[builtIn.id] or builtIn

		stagedById[definition.id] = definition
		table.insert(stagedOrdered, definition)
	end

	for _, definition: PropertyDefinition in gameDefinitions do
		if stagedById[definition.id] == nil then
			stagedById[definition.id] = definition
			table.insert(stagedOrdered, definition)
		end
	end

	return table.freeze({
		definitionsById = table.freeze(stagedById),
		orderedDefinitions = table.freeze(stagedOrdered),
	}) :: PreparedPropertyCatalog,
		nil
end

function PropertyRegistry.Publish(prepared: PreparedPropertyCatalog): (boolean, string?)
	if loaded then
		return false, "PropertyDefinitionsAlreadyLoaded"
	end

	definitionsById = prepared.definitionsById
	orderedDefinitions = prepared.orderedDefinitions
	loaded = true

	return true, nil
end

function PropertyRegistry.Load(definitions: { PropertyDefinition }): (boolean, string?)
	local prepared: PreparedPropertyCatalog?, reason: string? = PropertyRegistry.Prepare(definitions)

	if prepared == nil then
		return false, reason
	end

	return PropertyRegistry.Publish(prepared)
end

function PropertyRegistry.Get(propertyId: string): PropertyDefinition?
	return definitionsById[propertyId]
end

function PropertyRegistry.GetAll(): { PropertyDefinition }
	return orderedDefinitions
end

function PropertyRegistry.GetAllById(): { [string]: PropertyDefinition }
	return definitionsById
end

function PropertyRegistry.IsLoaded(): boolean
	return loaded
end

function PropertyRegistry._RollbackStartup(): ()
	loaded = false
	definitionsById = table.freeze({} :: { [string]: PropertyDefinition })
	orderedDefinitions = table.freeze({} :: { PropertyDefinition })
end

PropertyRegistry._resetForTests = PropertyRegistry._RollbackStartup

return PropertyRegistry
