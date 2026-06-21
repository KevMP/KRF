--!strict
local serverFolder = script.Parent.Parent.Parent
local TagTypes = require(serverFolder.Tags.types)

local PropertyResolver = {}

export type ModifierEntry = {
	modifier: TagTypes.PropertyModifier,
	stackCount: number,
}

function PropertyResolver.Resolve(baseValue: number, modifierEntries: { ModifierEntry }): number
	local winningSet: number? = nil

	local totalAdd: number = 0
	local totalMultiply: number = 1
	local effectiveMin: number? = nil
	local effectiveMax: number? = nil

	for _, entry: ModifierEntry in modifierEntries do
		local modifier: TagTypes.PropertyModifier = entry.modifier
		local stackCount: number = entry.stackCount

		if modifier.set ~= nil then
			if winningSet == nil or modifier.set < winningSet then
				winningSet = modifier.set
			end
		end

		if modifier.add ~= nil then
			totalAdd += modifier.add * stackCount
		end

		if modifier.multiply ~= nil then
			totalMultiply *= modifier.multiply ^ stackCount
		end

		if modifier.min ~= nil then
			if effectiveMin == nil or modifier.min > effectiveMin then
				effectiveMin = modifier.min
			end
		end

		if modifier.max ~= nil then
			if effectiveMax == nil or modifier.max < effectiveMax then
				effectiveMax = modifier.max
			end
		end
	end

	if winningSet ~= nil then
		return winningSet
	end

	local resolvedValue: number = (baseValue + totalAdd) * totalMultiply

	if effectiveMin ~= nil and resolvedValue < effectiveMin then
		resolvedValue = effectiveMin
	end

	if effectiveMax ~= nil and resolvedValue > effectiveMax then
		resolvedValue = effectiveMax
	end

	return resolvedValue
end

return PropertyResolver
