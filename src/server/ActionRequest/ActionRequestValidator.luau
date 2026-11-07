--!strict
local Types = require(script.Parent.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)

-- I5 TDD scaffold. Prepared Action membership and reserved command checks remain unimplemented.
local ActionRequestValidator: Types.ActionRequestValidatorModule = table.freeze({
	Validate = function(
		_catalog: ActionRequestTypes.ActionRequestCatalog,
		_actions: ActionTypes.PreparedActionCatalog,
		_commands: { NetworkingTypes.CommandDefinition }
	): (boolean, string?)
		return false, "ActionRequestValidationUnavailable"
	end,
})

return ActionRequestValidator
