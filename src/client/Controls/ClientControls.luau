--!strict
local Types = require(script.Parent.types)
local State = require(script.Parent.utils.ControlRuntimeState)

local facade: Types.ClientControls = {
	Apply = function(changeSet: Types.ControlChangeSet): (boolean, string?)
		local owner: Types.ControlOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.Apply(changeSet)
	end,
}

return table.freeze(facade)
