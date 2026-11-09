--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)

local DeviceInputs = {}

local function isGamepad(key: Enum.KeyCode?): boolean
	if key == nil then
		return false
	end

	local name: string = key.Name

	return string.sub(name, 1, 6) == "Button"
		or string.sub(name, 1, 10) == "Thumbstick"
		or name == "DPadUp"
		or name == "DPadDown"
		or name == "DPadLeft"
		or name == "DPadRight"
end

-- IAS supplies no physical device identity on InputAction signals. Exclusive
-- keyboard/mouse/touch bindings prove independence; ambiguous or gamepad
-- bindings conservatively depend on any disconnected gamepad.
function DeviceInputs.Affected(graph: Types.InputGraphSnapshot, device: Enum.UserInputType): { string }
	local result: { string } = {}

	for _, inputId in Value.Keys(graph.inputs) do
		local slots: { [string]: Types.BindingSnapshot } = graph.bindings[inputId]
		local affected: boolean = next(slots) == nil

		for _, slot in slots do
			local binding: Types.BindingDefinition = slot.definition

			if string.sub(device.Name, 1, 7) == "Gamepad" then
				affected = affected
					or binding.uiButton ~= nil
					or binding.uiModifier ~= nil
					or (binding.keyCode ~= nil and binding.keyCode.Value == 0)
					or isGamepad(binding.primaryModifier)
					or isGamepad(binding.secondaryModifier)
					or isGamepad(binding.keyCode)
					or isGamepad(binding.forward)
					or isGamepad(binding.backward)
					or isGamepad(binding.left)
					or isGamepad(binding.right)
					or isGamepad(binding.up)
					or isGamepad(binding.down)
			elseif device == Enum.UserInputType.Keyboard then
				affected = affected or (binding.keyCode ~= nil and not isGamepad(binding.keyCode))
			else
				affected = true
			end
		end

		if affected then
			table.insert(result, inputId)
		end
	end

	return result
end

return DeviceInputs
