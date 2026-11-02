--!strict
local Value = {}

function Value.IsFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Value.Equal(left: any, right: any): boolean
	if left == right then
		return true
	end

	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end

	for key, value in left do
		if not Value.Equal(value, right[key]) then
			return false
		end
	end

	for key in right do
		if left[key] == nil then
			return false
		end
	end

	return true
end

function Value.Keys(dictionary: { [string]: any }): { string }
	local keys: { string } = {}

	for key in dictionary do
		table.insert(keys, key)
	end

	table.sort(keys)

	return keys
end

function Value.IsTyped(inputType: Enum.InputActionType, value: any): boolean
	if inputType == Enum.InputActionType.Bool then
		return type(value) == "boolean"
	end

	if inputType == Enum.InputActionType.Direction1D then
		return Value.IsFinite(value)
	end

	if inputType == Enum.InputActionType.Direction3D then
		return typeof(value) == "Vector3"
			and Value.IsFinite(value.X)
			and Value.IsFinite(value.Y)
			and Value.IsFinite(value.Z)
	end

	return typeof(value) == "Vector2" and Value.IsFinite(value.X) and Value.IsFinite(value.Y)
end

function Value.Neutral(inputType: Enum.InputActionType): any
	if inputType == Enum.InputActionType.Bool then
		return false
	end

	if inputType == Enum.InputActionType.Direction1D then
		return 0
	end

	if inputType == Enum.InputActionType.Direction3D then
		return Vector3.zero
	end

	return Vector2.zero
end

return Value
