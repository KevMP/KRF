--!strict
local CommandValue = {}

-- Only schema-decoded values enter this helper. No consumer tables, identity
-- objects or callbacks are recursively frozen by Networking.
function CommandValue.Freeze(value: any): any
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child: any in value do
			CommandValue.Freeze(child)
		end

		table.freeze(value)
	end

	return value
end

return CommandValue
