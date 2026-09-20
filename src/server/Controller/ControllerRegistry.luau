--!strict
local ControllerTypes = require(script.Parent.types)

export type Controller = ControllerTypes.Controller
export type ControllerDef = ControllerTypes.ControllerDef
export type ControllerRegistry = ControllerTypes.ControllerRegistry

local ControllerRegistry = {} :: ControllerRegistry
local isLoaded: boolean = false
local byKey: { [string]: ControllerDef } = {}
local controllerDefKeys: { string } = {}

local function ResolveOrderInCatalog(
	keys: { string },
	definitionsByKey: { [string]: ControllerDef },
	catalogKeys: { string }
): ({ string }?, string?)
	local wantedByKey: { [string]: boolean } = {}
	local wantedCount: number = 0
	for _, key: string in keys do
		if definitionsByKey[key] == nil then
			return nil, "UnknownControllerKey:" .. key
		end
		if not wantedByKey[key] then
			wantedByKey[key] = true
			wantedCount += 1
		end
	end

	local inDegreeByKey: { [string]: number } = {}
	local dependentsByKey: { [string]: { string } } = {}
	for _, key: string in catalogKeys do
		if wantedByKey[key] then
			inDegreeByKey[key] = 0
			dependentsByKey[key] = {}
		end
	end

	for _, key: string in catalogKeys do
		if not wantedByKey[key] then
			continue
		end
		local seenDependencies: { [string]: boolean } = {}
		local dependencies: { string } = definitionsByKey[key].dependsOn or ({} :: { string })
		for _, dependencyKey: string in dependencies do
			if not wantedByKey[dependencyKey] then
				return nil, "DependencyNotInAttachSet:" .. key .. "->" .. dependencyKey
			end
			if not seenDependencies[dependencyKey] then
				seenDependencies[dependencyKey] = true
				inDegreeByKey[key] += 1
				table.insert(dependentsByKey[dependencyKey], key)
			end
		end
	end

	local orderedKeys: { string } = {}
	local processedByKey: { [string]: boolean } = {}
	for _ = 1, wantedCount do
		local nextKey: string? = nil
		for _, key: string in catalogKeys do
			if wantedByKey[key] and not processedByKey[key] and inDegreeByKey[key] == 0 then
				nextKey = key
				break
			end
		end
		if nextKey == nil then
			return nil, "CyclicDependency"
		end
		processedByKey[nextKey] = true
		table.insert(orderedKeys, nextKey)
		for _, dependentKey: string in dependentsByKey[nextKey] do
			inDegreeByKey[dependentKey] -= 1
		end
	end
	return orderedKeys, nil
end

function ControllerRegistry.Load(definitions: { ControllerDef }): (boolean, string?)
	if isLoaded then
		return false, "ControllerDefinitionsAlreadyLoaded"
	end
	if type(definitions) ~= "table" then
		return false, "ControllerCatalogMustBeTable"
	end

	local stagedByKey: { [string]: ControllerDef } = {}
	local stagedKeys: { string } = {}
	for _, definition: ControllerDef in definitions do
		if type(definition) ~= "table" then
			return false, "ControllerDefinitionMustBeTable"
		end
		if definition.key == nil then
			return false, "ControllerKeyMissing"
		end
		if type(definition.key) ~= "string" then
			return false, "ControllerKeyMustBeString"
		end
		if definition.key == "" then
			return false, "ControllerKeyCannotBeEmpty"
		end
		if stagedByKey[definition.key] ~= nil then
			return false, "DuplicateControllerKey"
		end
		if type(definition.factory) ~= "function" then
			return false, "ControllerFactoryMustBeFunction"
		end
		if definition.autoAttach ~= nil and type(definition.autoAttach) ~= "boolean" then
			return false, "ControllerAutoAttachMustBeBoolean"
		end

		local dependencies: { string }? = nil
		if definition.dependsOn ~= nil then
			if type(definition.dependsOn) ~= "table" then
				return false, "ControllerDependenciesMustBeTable"
			end
			local copiedDependencies: { string } = {}
			for _, dependencyKey: string in definition.dependsOn do
				if type(dependencyKey) ~= "string" or dependencyKey == "" then
					return false, "ControllerDependencyKeyInvalid"
				end
				table.insert(copiedDependencies, dependencyKey)
			end
			dependencies = table.freeze(copiedDependencies)
		end

		stagedByKey[definition.key] = table.freeze({
			key = definition.key,
			factory = definition.factory,
			dependsOn = dependencies,
			autoAttach = definition.autoAttach,
		}) :: ControllerDef
		table.insert(stagedKeys, definition.key)
	end

	for _, key: string in stagedKeys do
		local dependencies: { string } = stagedByKey[key].dependsOn or ({} :: { string })
		for _, dependencyKey: string in dependencies do
			if stagedByKey[dependencyKey] == nil then
				return false, "MissingDependency:" .. key .. "->" .. dependencyKey
			end
		end
	end
	local orderedKeys: { string }?, reason: string? = ResolveOrderInCatalog(stagedKeys, stagedByKey, stagedKeys)
	if orderedKeys == nil then
		return false, reason
	end

	byKey = table.freeze(stagedByKey)
	controllerDefKeys = table.freeze(stagedKeys)
	isLoaded = true
	return true, nil
end

function ControllerRegistry.IsLoaded(): boolean
	return isLoaded
end

function ControllerRegistry.GetKeys(): { string }
	return table.clone(controllerDefKeys)
end

function ControllerRegistry.Get(key: string): ControllerDef?
	return byKey[key]
end

function ControllerRegistry.GetAutoAttachKeys(): { string }
	local keys: { string } = {}
	for _, key: string in controllerDefKeys do
		if byKey[key].autoAttach ~= false then
			table.insert(keys, key)
		end
	end
	return keys
end

function ControllerRegistry.ResolveOrder(keys: { string }): ({ string }?, string?)
	return ResolveOrderInCatalog(keys, byKey, controllerDefKeys)
end

function ControllerRegistry._ResetForTests(): ()
	isLoaded = false
	byKey = {}
	controllerDefKeys = {}
end

return ControllerRegistry
