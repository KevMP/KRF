--!strict
function requireDescendants(root: Instance): { any }
	local modules: { ModuleScript } = {}

	for _, descendant: Instance in root:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			table.insert(modules, descendant)
		end
	end

	table.sort(modules, function(left: ModuleScript, right: ModuleScript): boolean
		return left:GetFullName() < right:GetFullName()
	end)

	local results: { any } = {}

	for _, module: ModuleScript in modules do
		local result: any = (require :: any)(module)
		table.insert(results, result)
	end

	return results
end

return requireDescendants
