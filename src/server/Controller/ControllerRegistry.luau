--!strict
local ControllerTypes = require(script.Parent.types)

export type Controller = ControllerTypes.Controller
export type ControllerDef = ControllerTypes.ControllerDef
export type ControllerRegistry = ControllerTypes.ControllerRegistry

local ControllerRegistry = {} :: ControllerRegistry
local byKey: { [string]: ControllerDef } = {}
local controllerDefKeys: { string } = {}

function ControllerRegistry.Register(controllerDefinition: ControllerDef)
	if byKey[controllerDefinition.key] then
		return false, "DuplicateControllerKey"
	end
	byKey[controllerDefinition.key] = controllerDefinition
	table.insert(controllerDefKeys, controllerDefinition.key)
	return true, nil
end

function ControllerRegistry.GetKeys(): { string }
	return table.clone(controllerDefKeys)
end

function ControllerRegistry.Get(key: string): ControllerDef?
	return byKey[key]
end

function ControllerRegistry.GetAutoAttachKeys(): { string }
	local keys: { string } = {}
	for _, key in ControllerRegistry.GetKeys() do
		local controller: ControllerDef? = ControllerRegistry.Get(key)
		if controller and controller.autoAttach ~= false then
			table.insert(keys, key)
		end
	end
	return keys
end

function ControllerRegistry.ResolveOrder(keys: { string }): ({ string }?, string?)
	--AI Gen Topsort algorithim just gonna trust and heavily unit test
	-- Candidate set (unique keys)
	local isWantedByKey: { [string]: boolean } = {}
	local wantedCount: number = 0

	for _, key: string in keys do
		if isWantedByKey[key] ~= true then
			isWantedByKey[key] = true
			wantedCount += 1
		end

		if byKey[key] == nil then
			return nil, "UnknownControllerKey:" .. key
		end
	end

	-- Build indegree + dependents adjacency list within the candidate set
	local inDegreeByKey: { [string]: number } = {}
	local dependentsByKey: { [string]: { string } } = {}

	for key: string, isWanted: boolean in isWantedByKey do
		if isWanted then
			inDegreeByKey[key] = 0
			dependentsByKey[key] = {}
		end
	end

	for key: string, isWanted: boolean in isWantedByKey do
		if isWanted then
			local controllerDef: ControllerDef = byKey[key]
			local dependsOn: { string }? = controllerDef.dependsOn

			if dependsOn ~= nil then
				for _, dependencyKey: string in dependsOn do
					if byKey[dependencyKey] == nil then
						return nil, "MissingDependency:" .. key .. "->" .. dependencyKey
					end

					if isWantedByKey[dependencyKey] ~= true then
						return nil, "DependencyNotInAttachSet:" .. key .. "->" .. dependencyKey
					end

					local dependents: { string } = dependentsByKey[dependencyKey]
					table.insert(dependents, key)

					inDegreeByKey[key] = inDegreeByKey[key] + 1
				end
			end
		end
	end

	-- Deterministic Kahn: repeatedly pick the earliest-registered node with indegree 0
	local orderedKeys: { string } = {}
	local isProcessedByKey: { [string]: boolean } = {}
	local processedCount: number = 0

	for _iterationIndex: number = 1, wantedCount do
		local nextKey: string? = nil

		for _, candidateKey: string in controllerDefKeys do
			if isWantedByKey[candidateKey] == true and isProcessedByKey[candidateKey] ~= true then
				local inDegree: number = inDegreeByKey[candidateKey]
				if inDegree == 0 then
					nextKey = candidateKey
					break
				end
			end
		end

		if nextKey == nil then
			return nil, "CyclicDependency"
		end

		isProcessedByKey[nextKey] = true
		table.insert(orderedKeys, nextKey)
		processedCount += 1

		local dependents: { string } = dependentsByKey[nextKey]
		for _, dependentKey: string in dependents do
			inDegreeByKey[dependentKey] = inDegreeByKey[dependentKey] - 1
		end
	end

	return orderedKeys, nil
end

--Only used in tests
function ControllerRegistry._ResetForTests(): ()
	table.clear(byKey)
	table.clear(controllerDefKeys)
end

return ControllerRegistry
