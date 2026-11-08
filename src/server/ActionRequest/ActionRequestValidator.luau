--!strict
local Types = require(script.Parent.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local SchemaCollectionUtils = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)

local RESERVED_COMMAND_IDS: { [string]: boolean } = {
	[Constants.START_COMMAND_ID] = true,
	[Constants.STOP_COMMAND_ID] = true,
	[Constants.INTERRUPT_COMMAND_ID] = true,
}

table.freeze(RESERVED_COMMAND_IDS)

local ActionRequestValidator: Types.ActionRequestValidatorModule = table.freeze({
	ValidateCatalog = function(
		catalog: ActionRequestTypes.ActionRequestCatalog,
		actions: ActionTypes.PreparedActionCatalog
	): (boolean, string?)
		for _, actionId: string in catalog.actionIds do
			if actions.definitionsById[actionId] == nil then
				return false, "ActionRequestUnknownAction"
			end
		end

		return true, nil
	end,

	-- Malformed command arrays are left to CommandRegistry so its own reasons stay stable.
	ValidateReservedCommands = function(commands: any): (boolean, string?)
		local count: number? = if type(commands) == "table" then SchemaCollectionUtils.GetArrayLength(commands) else nil

		for index: number = 1, count or 0 do
			local definition: any = rawget(commands, index)
			local id: any = if type(definition) == "table" then rawget(definition, "id") else nil

			if type(id) == "string" and RESERVED_COMMAND_IDS[id] then
				return false, "CommandIdReserved"
			end
		end

		return true, nil
	end,
})

return ActionRequestValidator
