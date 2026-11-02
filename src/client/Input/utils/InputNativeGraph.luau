--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)

export type Owner = {
	Apply: (
		previous: Types.InputGraphSnapshot,
		nextGraph: Types.InputGraphSnapshot,
		invalidated: { [string]: string }
	) -> (boolean, string?),
	Actions: () -> { [string]: InputAction },
	Destroy: () -> (),
}

local NativeGraph = {}

function NativeGraph.new(native: Types.NativeInputAdapter, receive: (string, Types.NativeTransition, any) -> ()): Owner
	local contexts: { [string]: InputContext } = {}
	local actions: { [string]: InputAction } = {}
	local bindings: { [string]: { [string]: InputBinding } } = {}
	local listeners: { [string]: { stop: () -> (), token: {} } } = {}
	local active: boolean = true
	local destroyed: boolean = false

	local function listen(inputId: string, action: InputAction): ()
		local old = listeners[inputId]

		if old ~= nil then
			old.stop()
		end

		local token = {}

		local stop: () -> () = native.ObserveAction(action, function(kind: Types.NativeTransition, value: any): ()
			local listener = listeners[inputId]

			if active and listener ~= nil and listener.token == token then
				receive(inputId, kind, value)
			end
		end)

		listeners[inputId] = { stop = stop, token = token }
	end

	local function destroy(): ()
		if destroyed then
			return
		end

		destroyed = true
		active = false

		for _, listener in listeners do
			pcall(listener.stop)
		end

		for _, context: InputContext in contexts do
			pcall(native.ConfigureContext, context, { priority = context.Priority, sink = context.Sink }, false)
		end

		table.clear(listeners)
		table.clear(contexts)
		table.clear(actions)
		table.clear(bindings)
		native.DestroyContainer()
	end

	return {
		Actions = function(): { [string]: InputAction }
			return actions
		end,
		Destroy = destroy,
		Apply = function(
			previous: Types.InputGraphSnapshot,
			nextGraph: Types.InputGraphSnapshot,
			invalidated: { [string]: string }
		): (boolean, string?)
			local nextContexts: { [string]: InputContext } = table.clone(contexts)
			local nextActions: { [string]: InputAction } = table.clone(actions)
			local nextBindings: { [string]: { [string]: InputBinding } } = {}
			local created: { Instance } = {}
			local retired: { Instance } = {}
			local undo: { () -> () } = {}
			local irreversible: boolean = false

			local success: boolean = pcall(function(): ()
				for _, contextId: string in Value.Keys(nextGraph.contexts) do
					local desired: Types.ContextSnapshot = nextGraph.contexts[contextId]
					local old: Types.ContextSnapshot? = previous.contexts[contextId]

					if old == nil then
						local context: InputContext =
							native.CreateContext(contextId, { priority = desired.priority, sink = desired.sink })

						nextContexts[contextId] = context
						table.insert(created, context)
					end
				end

				for _, inputId: string in Value.Keys(nextGraph.inputs) do
					local desired: Types.InputSnapshot = nextGraph.inputs[inputId]
					local old: Types.InputSnapshot? = previous.inputs[inputId]

					local replaced: boolean = old == nil
						or old.inputType ~= desired.inputType
						or old.contextId ~= desired.contextId

					local action: InputAction
					local slots: { [string]: InputBinding } = {}

					if replaced then
						action = native.CreateAction(inputId, {
							context = desired.contextId,
							type = desired.inputType,
							displayName = desired.displayName,
							bindings = {},
						}, nextContexts[desired.contextId])

						table.insert(created, action)
						nextActions[inputId] = action

						if actions[inputId] ~= nil then
							table.insert(retired, actions[inputId])
						end
					else
						action = actions[inputId]
						local oldName: string = action.DisplayName

						if oldName ~= (desired.displayName or inputId) then
							table.insert(undo, function()
								action.DisplayName = oldName
							end)

							action.DisplayName = desired.displayName or inputId
						end
					end

					for _, slot: string in Value.Keys(nextGraph.bindings[inputId]) do
						local config: Types.BindingDefinition = nextGraph.bindings[inputId][slot].definition

						local oldConfig: Types.BindingSnapshot? = if old ~= nil
							then previous.bindings[inputId][slot]
							else nil

						if not replaced and oldConfig ~= nil and Value.Equal(oldConfig.definition, config) then
							slots[slot] = bindings[inputId][slot]
						else
							local binding: InputBinding = native.CreateBinding(slot, config, action)
							table.insert(created, binding)
							slots[slot] = binding

							if not replaced and oldConfig ~= nil then
								table.insert(retired, bindings[inputId][slot])
							end
						end
					end

					if not replaced then
						for slot: string, oldBinding: InputBinding in bindings[inputId] do
							if slots[slot] == nil then
								table.insert(retired, oldBinding)
							end
						end
					end

					nextBindings[inputId] = slots
				end

				for _, contextId: string in Value.Keys(nextGraph.contexts) do
					local desired: Types.ContextSnapshot = nextGraph.contexts[contextId]
					local old: Types.ContextSnapshot? = previous.contexts[contextId]

					if old ~= nil and not Value.Equal(old, desired) then
						local context: InputContext = contexts[contextId]

						table.insert(undo, function(): ()
							native.ConfigureContext(context, { priority = old.priority, sink = old.sink }, old.enabled)
						end)

						native.ConfigureContext(
							context,
							{ priority = desired.priority, sink = desired.sink },
							desired.enabled
						)
					elseif old == nil and desired.enabled then
						native.ConfigureContext(
							nextContexts[contextId],
							{ priority = desired.priority, sink = desired.sink },
							true
						)
					end
				end

				for inputId: string, action: InputAction in actions do
					if nextGraph.inputs[inputId] == nil then
						nextActions[inputId] = nil
						table.insert(retired, action)
					end
				end

				for contextId: string, context: InputContext in contexts do
					if nextGraph.contexts[contextId] == nil then
						nextContexts[contextId] = nil
						table.insert(retired, context)
					end
				end

				irreversible = true

				for inputId: string, listener in table.clone(listeners) do
					if nextActions[inputId] == nil then
						listeners[inputId] = nil
						listener.stop()
					end
				end

				for _, inputId: string in Value.Keys(nextActions) do
					if actions[inputId] ~= nextActions[inputId] or invalidated[inputId] ~= nil then
						listen(inputId, nextActions[inputId])
					end
				end

				for _, instance: Instance in retired do
					native.Destroy(instance)
				end
			end)

			if not success then
				if irreversible then
					return false, "InputRuntimeFaulted"
				end

				local restored: boolean = true

				for index: number = #undo, 1, -1 do
					if not pcall(undo[index]) then
						restored = false
					end
				end

				for index: number = #created, 1, -1 do
					if not pcall(native.Destroy, created[index]) then
						restored = false
					end
				end

				for contextId: string, context: InputContext in contexts do
					local old: Types.ContextSnapshot = previous.contexts[contextId]

					if
						context.Parent == nil
						or context.Enabled ~= old.enabled
						or context.Priority ~= old.priority
						or context.Sink ~= old.sink
					then
						restored = false
					end
				end

				for inputId: string, action: InputAction in actions do
					if action.Parent ~= contexts[previous.inputs[inputId].contextId] then
						restored = false
					end

					for _, binding: InputBinding in bindings[inputId] do
						if binding.Parent ~= action then
							restored = false
						end
					end
				end

				return false, if restored then "NativeCommitFailed" else "InputRuntimeFaulted"
			end

			contexts = nextContexts
			actions = nextActions
			bindings = nextBindings

			return true, nil
		end,
	}
end

return NativeGraph
