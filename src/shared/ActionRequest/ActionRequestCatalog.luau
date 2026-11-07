--!strict
local Types = require(script.Parent.types)

-- I5 TDD scaffold. Schema validation, codec compilation and contract tags remain unimplemented.
local ActionRequestCatalog: Types.ActionRequestCatalogModule = table.freeze({
	Compile = function(_schemas: any): (Types.ActionRequestCatalog?, string?)
		return nil, "ActionRequestCatalogUnavailable"
	end,
})

return ActionRequestCatalog
