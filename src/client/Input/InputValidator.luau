--!strict
local Types = require(script.Parent.types)
local Constants = require(script.Parent.utils.InputConstants)
local Value = require(script.Parent.utils.InputValue)

local Validator = {}
local sourceFields = { priority = true, contexts = true, inputs = true, bindingOverrides = true }
local inputFields = { context = true, type = true, displayName = true, bindings = true }
local contextFields = { priority = true, sink = true }

local supportedTypes = {
	[Enum.InputActionType.Bool] = true,
	[Enum.InputActionType.Direction1D] = true,
	[Enum.InputActionType.Direction2D] = true,
	[Enum.InputActionType.Direction3D] = true,
	[Enum.InputActionType.ViewportPosition] = true,
}

local bindingFields = {
	keyCode = "KeyCode",
	forward = "KeyCode",
	backward = "KeyCode",
	left = "KeyCode",
	right = "KeyCode",
	up = "KeyCode",
	down = "KeyCode",
	primaryModifier = "KeyCode",
	secondaryModifier = "KeyCode",
	pressedThreshold = "number",
	releasedThreshold = "number",
	scale = "number",
	vector2Scale = "Vector2",
	vector3Scale = "Vector3",
	responseCurve = "number",
	clampMagnitudeToOne = "boolean",
	pointerIndex = "number",
	uiButton = "GuiButton",
	uiModifier = "GuiButton",
	displayName = "string",
	displayImage = "Content",
}

local function plain(value: any): boolean
	return type(value) == "table" and getmetatable(value) == nil
end

local function id(value: any): boolean
	return type(value) == "string" and #value > 0
end

local function fields(value: any, allowed: { [string]: any }): boolean
	if not plain(value) then
		return false
	end

	for key in value do
		if type(key) ~= "string" or allowed[key] == nil then
			return false
		end
	end

	return true
end

local function count(value: any, maximum: number): boolean
	local total: number = 0

	for _ in value do
		total += 1

		if total > maximum then
			return false
		end
	end

	return true
end

local function binding(value: any, inputType: Enum.InputActionType?): Types.BindingDefinition?
	if not fields(value, bindingFields) or next(value) == nil then
		return nil
	end

	local owned: any = {}

	for field: string, entry: any in value do
		local expected: string = bindingFields[field]

		if expected == "KeyCode" then
			if typeof(entry) ~= "EnumItem" or entry.EnumType ~= Enum.KeyCode then
				return nil
			end
		elseif expected == "number" then
			if not Value.IsFinite(entry) or math.abs(entry) > Constants.NATIVE_FLOAT_MAX then
				return nil
			end
		elseif expected == "GuiButton" then
			if typeof(entry) ~= "Instance" or not (entry :: Instance):IsA("GuiButton") then
				return nil
			end
		elseif typeof(entry) ~= expected then
			return nil
		end

		if expected == "Vector2" and not Value.IsTyped(Enum.InputActionType.Direction2D, entry) then
			return nil
		end

		if expected == "Vector3" and not Value.IsTyped(Enum.InputActionType.Direction3D, entry) then
			return nil
		end

		owned[field] = entry
	end

	if
		value.pointerIndex ~= nil
		and (value.pointerIndex < 0 or value.pointerIndex > Constants.NATIVE_INT_MAX or value.pointerIndex % 1 ~= 0)
	then
		return nil
	end

	if value.responseCurve ~= nil and (value.responseCurve < 1 or value.responseCurve > 10) then
		return nil
	end

	if value.pressedThreshold ~= nil and (value.pressedThreshold < 0 or value.pressedThreshold > 1) then
		return nil
	end

	if value.releasedThreshold ~= nil and (value.releasedThreshold < 0 or value.releasedThreshold > 1) then
		return nil
	end

	if (value.pressedThreshold or 0.5) < (value.releasedThreshold or 0.2) then
		return nil
	end

	if inputType ~= nil then
		local bool: boolean = inputType == Enum.InputActionType.Bool
		local viewport: boolean = inputType == Enum.InputActionType.ViewportPosition
		local direction: boolean = not bool and not viewport
		local keyName: string? = if value.keyCode ~= nil then value.keyCode.Name else nil
		local vectorKey: boolean = keyName == "Thumbstick1" or keyName == "Thumbstick2" or keyName == "MouseDelta"

		if value.keyCode ~= nil then
			if inputType == Enum.InputActionType.Direction2D and not vectorKey then
				return nil
			end

			if inputType == Enum.InputActionType.Direction3D then
				return nil
			end

			if
				(bool or inputType == Enum.InputActionType.Direction1D)
				and (vectorKey or keyName == "MousePosition" or keyName == "Touch")
			then
				return nil
			end
		end

		if (value.forward ~= nil or value.backward ~= nil) and inputType ~= Enum.InputActionType.Direction3D then
			return nil
		end

		if
			(value.left ~= nil or value.right ~= nil)
			and inputType ~= Enum.InputActionType.Direction2D
			and inputType ~= Enum.InputActionType.Direction3D
		then
			return nil
		end

		if
			(value.up ~= nil or value.down ~= nil or value.scale ~= nil or value.clampMagnitudeToOne ~= nil)
			and not direction
		then
			return nil
		end

		if value.vector2Scale ~= nil and inputType ~= Enum.InputActionType.Direction2D then
			return nil
		end

		if value.vector3Scale ~= nil and inputType ~= Enum.InputActionType.Direction3D then
			return nil
		end

		if (value.pressedThreshold ~= nil or value.releasedThreshold ~= nil or value.uiButton ~= nil) and not bool then
			return nil
		end

		if value.pointerIndex ~= nil and not viewport then
			return nil
		end

		if
			value.responseCurve ~= nil
			and (
				inputType ~= Enum.InputActionType.Direction2D
				or (value.keyCode ~= Enum.KeyCode.Thumbstick1 and value.keyCode ~= Enum.KeyCode.Thumbstick2)
			)
		then
			return nil
		end

		if
			viewport
			and (
				value.keyCode == nil or (value.keyCode ~= Enum.KeyCode.MousePosition and value.keyCode.Name ~= "Touch")
			)
		then
			return nil
		end

		if
			value.keyCode == nil
			and value.uiButton == nil
			and value.up == nil
			and value.down == nil
			and value.left == nil
			and value.right == nil
			and value.forward == nil
			and value.backward == nil
		then
			return nil
		end
	end

	return table.freeze(owned) :: Types.BindingDefinition
end

function Validator.Normalize(sourceId: string, declaration: any): (Types.InputSourceDefinition?, string?)
	if not id(sourceId) then
		return nil, "InvalidSourceId"
	end

	if
		not fields(declaration, sourceFields)
		or (declaration.priority ~= nil and not Value.IsFinite(declaration.priority))
	then
		return nil, "InvalidDefinition"
	end

	for _, field: string in { "contexts", "inputs", "bindingOverrides" } do
		if declaration[field] ~= nil and not plain(declaration[field]) then
			return nil, "InvalidDefinition"
		end
	end

	local contexts: { [string]: Types.ContextDefinition } = {}
	local inputs: { [string]: Types.InputDefinition } = {}
	local overrides: { [string]: { [string]: Types.BindingDefinition } } = {}
	local rawContexts: any = declaration.contexts or {}
	local rawInputs: any = declaration.inputs or {}

	if not count(rawContexts, Constants.MAX_CONTEXTS) then
		return nil, "InputContextLimitExceeded"
	end

	if not count(rawInputs, Constants.MAX_INPUTS) then
		return nil, "InputLimitExceeded"
	end

	for contextId: any, definition: any in rawContexts do
		if
			not id(contextId)
			or not fields(definition, contextFields)
			or not Value.IsFinite(definition.priority)
			or definition.priority < Constants.NATIVE_INT_MIN
			or definition.priority > Constants.NATIVE_INT_MAX
			or definition.priority % 1 ~= 0
			or type(definition.sink) ~= "boolean"
		then
			return nil, "InvalidContext"
		end

		contexts[contextId] = table.freeze({ priority = definition.priority, sink = definition.sink })
	end

	local totalBindings: number = 0

	for inputId: any, definition: any in rawInputs do
		if
			not id(inputId)
			or not fields(definition, inputFields)
			or not id(definition.context)
			or not plain(definition.bindings)
			or typeof(definition.type) ~= "EnumItem"
			or definition.type.EnumType ~= Enum.InputActionType
			or supportedTypes[definition.type] ~= true
			or (definition.displayName ~= nil and type(definition.displayName) ~= "string")
		then
			return nil, "InvalidInput"
		end

		local bindings: { [string]: Types.BindingDefinition } = {}

		for slot: any, config: any in definition.bindings do
			totalBindings += 1

			if totalBindings > Constants.MAX_BINDINGS then
				return nil, "InputBindingLimitExceeded"
			end

			local normalized: Types.BindingDefinition? = binding(config, definition.type)

			if not id(slot) or normalized == nil then
				return nil, "InvalidBinding"
			end

			bindings[slot] = normalized
		end

		inputs[inputId] = table.freeze({
			context = definition.context :: string,
			type = definition.type :: Enum.InputActionType,
			displayName = definition.displayName :: string?,
			bindings = table.freeze(bindings),
		}) :: Types.InputDefinition
	end

	local totalOverrides: number = 0

	if not count(declaration.bindingOverrides or {}, Constants.MAX_INPUTS) then
		return nil, "InputOverrideLimitExceeded"
	end

	for inputId: any, slots: any in declaration.bindingOverrides or {} do
		if not id(inputId) or not plain(slots) then
			return nil, "InvalidBinding"
		end

		local normalizedSlots: { [string]: Types.BindingDefinition } = {}

		for slot: any, config: any in slots do
			totalOverrides += 1

			if totalOverrides > Constants.MAX_OVERRIDES then
				return nil, "InputOverrideLimitExceeded"
			end

			local normalized: Types.BindingDefinition? = binding(config, nil)

			if not id(slot) or normalized == nil then
				return nil, "InvalidBinding"
			end

			normalizedSlots[slot] = normalized
		end

		overrides[inputId] = table.freeze(normalizedSlots)
	end

	return table.freeze({
		priority = declaration.priority or 0,
		contexts = table.freeze(contexts),
		inputs = table.freeze(inputs),
		bindingOverrides = table.freeze(overrides),
	}),
		nil
end

function Validator.Compose(
	sources: { [string]: Types.InputSourceDefinition },
	previous: Types.InputGraphSnapshot
): (Types.InputGraphSnapshot?, string?)
	if not count(sources, Constants.MAX_SOURCES) then
		return nil, "InputSourceLimitExceeded"
	end

	local contexts: { [string]: Types.ContextSnapshot } = {}
	local inputs: { [string]: Types.InputSnapshot } = {}
	local bindings: { [string]: { [string]: Types.BindingSnapshot } } = {}
	local totalBindings: number = 0

	for _, sourceId: string in Value.Keys(sources) do
		local source: Types.InputSourceDefinition = sources[sourceId]

		for contextId: string, definition: Types.ContextDefinition in source.contexts or {} do
			if contexts[contextId] ~= nil then
				return nil, "DuplicateContextOwner"
			end

			local old: Types.ContextSnapshot? = previous.contexts[contextId]

			contexts[contextId] = table.freeze({
				id = contextId,
				sourceId = sourceId,
				priority = definition.priority,
				sink = definition.sink,
				enabled = old ~= nil and old.sourceId == sourceId and old.enabled,
			})
		end
	end

	if not count(contexts, Constants.MAX_CONTEXTS) then
		return nil, "InputContextLimitExceeded"
	end

	for _, sourceId: string in Value.Keys(sources) do
		local source: Types.InputSourceDefinition = sources[sourceId]

		for inputId: string, definition: Types.InputDefinition in source.inputs or {} do
			if inputs[inputId] ~= nil then
				return nil, "DuplicateInputOwner"
			end

			if contexts[definition.context] == nil then
				return nil, "UnknownContext"
			end

			inputs[inputId] = table.freeze({
				id = inputId,
				sourceId = sourceId,
				contextId = definition.context,
				inputType = definition.type,
				displayName = definition.displayName,
			})

			local slots: { [string]: Types.BindingSnapshot } = {}

			for slot: string, config: Types.BindingDefinition in definition.bindings do
				totalBindings += 1
				slots[slot] = table.freeze({ sourceId = sourceId, definition = config })
			end

			bindings[inputId] = slots
		end
	end

	if not count(inputs, Constants.MAX_INPUTS) then
		return nil, "InputLimitExceeded"
	end

	if totalBindings > Constants.MAX_BINDINGS then
		return nil, "InputBindingLimitExceeded"
	end

	local winners: { [string]: { [string]: { priority: number, tied: boolean } } } = {}
	local totalOverrides: number = 0

	for _, sourceId: string in Value.Keys(sources) do
		local source: Types.InputSourceDefinition = sources[sourceId]

		for inputId: string, slots: { [string]: Types.BindingDefinition } in source.bindingOverrides or {} do
			local input: Types.InputSnapshot? = inputs[inputId]

			if input == nil then
				return nil, "UnknownInput"
			end

			local winningSlots = winners[inputId] or {}

			winners[inputId] = winningSlots

			for slot: string, config: Types.BindingDefinition in slots do
				totalOverrides += 1

				if totalOverrides > Constants.MAX_OVERRIDES then
					return nil, "InputOverrideLimitExceeded"
				end

				if bindings[inputId][slot] == nil then
					return nil, "UnknownBindingSlot"
				end

				if binding(config, input.inputType) == nil then
					return nil, "InvalidBinding"
				end

				local winner = winningSlots[slot]
				local priority: number = source.priority or 0

				if winner == nil or priority > winner.priority then
					winningSlots[slot] = { priority = priority, tied = false }
					bindings[inputId][slot] = table.freeze({ sourceId = sourceId, definition = config })
				elseif priority == winner.priority then
					winner.tied = true
				end
			end
		end
	end

	for _, slots in winners do
		for _, winner in slots do
			if winner.tied then
				return nil, "BindingOverrideConflict"
			end
		end
	end

	for _, slots in bindings do
		table.freeze(slots)
	end

	return table.freeze({
		generation = previous.generation + 1,
		sources = table.freeze(table.clone(sources)),
		contexts = table.freeze(contexts),
		inputs = table.freeze(inputs),
		bindings = table.freeze(bindings),
	}),
		nil
end

return Validator
