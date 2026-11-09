--!strict
local Types = require(script.Parent.Parent.types)

-- A physical driver can be bound by several IAS actions. Modifiers and response
-- settings cannot prove independence when the driving key/button is shared.
type Driver = Enum.KeyCode | GuiButton | string
type Drivers = { [Driver]: boolean }

export type Blocked = { [string]: Drivers }

local Ownership = {}

local function drivers(graph: Types.InputGraphSnapshot, inputId: string): Drivers
	local result: Drivers = {}

	for _, slot: Types.BindingSnapshot in graph.bindings[inputId] do
		local binding: Types.BindingDefinition = slot.definition

		if graph.inputs[inputId].inputType == Enum.InputActionType.ViewportPosition then
			local key: Enum.KeyCode = assert(binding.keyCode, "Expected viewport driver")

			result[key.Name .. ":" .. tostring(binding.pointerIndex or 0)] = true
		else
			for _, key: Enum.KeyCode? in
				{
					binding.keyCode,
					binding.forward,
					binding.backward,
					binding.left,
					binding.right,
					binding.up,
					binding.down,
				}
			do
				if key ~= nil and key.Value ~= 0 then
					result[key] = true
				end
			end
		end

		if binding.uiButton ~= nil then
			result[binding.uiButton] = true
		end
	end

	return result
end

-- Configuration-time reachability only: no physical state or runtime registry.
-- An inverted driver index avoids comparing every binding with every other one.
function Ownership.Blocked(graph: Types.InputGraphSnapshot): Blocked
	local inputs: { [string]: Drivers } = {}
	local highestSink: { [Driver]: number } = {}

	for inputId, input: Types.InputSnapshot in graph.inputs do
		local context: Types.ContextSnapshot = graph.contexts[input.contextId]

		if context.enabled then
			local keys: Drivers = drivers(graph, inputId)

			inputs[inputId] = keys

			if context.sink then
				for key in keys do
					highestSink[key] = math.max(highestSink[key] or -math.huge, context.priority)
				end
			end
		end
	end

	local blocked: Blocked = {}

	for inputId, keys in inputs do
		local context: Types.ContextSnapshot = graph.contexts[graph.inputs[inputId].contextId]

		for key in keys do
			local priority: number? = highestSink[key]

			if priority ~= nil and priority > context.priority then
				local affected: Drivers = blocked[inputId] or {}
				affected[key] = true
				blocked[inputId] = affected
			end
		end
	end

	return blocked
end

return Ownership
