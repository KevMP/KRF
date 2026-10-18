--!strict
local SchemaCollectionUtils = {}

local MAX_SAFE_INTEGER: number = 9007199254740991

function SchemaCollectionUtils.IsPositiveInteger(value: any): boolean
	return type(value) == "number" and value > 0 and value <= MAX_SAFE_INTEGER and value % 1 == 0
end

function SchemaCollectionUtils.GetArrayLength(value: any): number?
	if type(value) ~= "table" then
		return nil
	end

	local count: number = 0
	local maximumIndex: number = 0

	-- Read stored entries only: consumer metatables must not supply fields or run
	-- code during schema admission or untrusted runtime value validation.
	for key: any in next, value do
		if not SchemaCollectionUtils.IsPositiveInteger(key) then
			return nil
		end

		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end

	return if maximumIndex == count then count else nil
end

return SchemaCollectionUtils
