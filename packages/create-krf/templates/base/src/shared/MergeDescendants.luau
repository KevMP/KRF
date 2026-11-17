--!strict
local requireDescendants = require(script.Parent.RequireDescendants)

function mergeDescendants(root: Instance): { [string]: any }
	local merged: { [string]: any } = {}

	for _, entries: { [string]: any } in requireDescendants(root) do
		for key: string, value: any in entries do
			assert(merged[key] == nil, `{root:GetFullName()} declares {key} more than once`)
			merged[key] = value
		end
	end

	return merged
end

return mergeDescendants
