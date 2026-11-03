--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)
local Constants = require(script.Parent.InputConstants)
local Validation = {}

function Validation.Plain(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end

function Validation.Id(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 256
end

function Validation.Fields(value: any, allowed: { [string]: boolean }): boolean
	if not Validation.Plain(value) then
		return false
	end

	for key in value do
		if allowed[key] ~= true then
			return false
		end
	end

	return true
end

function Validation.Duration(value: any): boolean
	return Value.IsFinite(value) and value > 0 and value <= Constants.MAX_RECOGNITION_WINDOW_SECONDS
end

function Validation.Array(value: any, maximum: number): boolean
	if not Validation.Plain(value) or #value > maximum then
		return false
	end

	local count: number = 0

	for index in value do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value then
			return false
		end

		count += 1
	end

	return count == #value
end

function Validation.CopyIds(value: any, maximum: number): { string }?
	if not Validation.Array(value, maximum) then
		return nil
	end

	local ids: { string } = {}
	local seen: { [string]: boolean } = {}

	for _, id: any in value do
		if not Validation.Id(id) or seen[id] then
			return nil
		end

		seen[id] = true
		table.insert(ids, id)
	end

	table.sort(ids)

	return table.freeze(ids)
end

-- Length-prefix IDs so arbitrary consumer strings cannot alias token namespaces.
function Validation.InputKey(inputId: string, kind: string): string
	return "I" .. tostring(#inputId) .. ":" .. inputId .. kind
end

function Validation.CustomKey(recognizerId: string): string
	return "C" .. recognizerId
end

function Validation.TokenKey(step: Types.WatchedToken): string
	return if step.kind == "Custom"
		then Validation.CustomKey(step.recognizerId)
		else Validation.InputKey(step.inputId, step.kind)
end

function Validation.After(deadline: number): number
	return deadline + math.max(0.000001, math.abs(deadline) * 2 ^ -50)
end

return Validation
