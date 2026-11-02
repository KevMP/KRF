--!strict
local Types = require(script.Parent.types)
local State = require(script.Parent.utils.InputRuntimeState)

local facade: Types.InputRuntime = {
	OnInput = State.OnInput,
	SetSource = function(sourceId: string, definition: Types.InputSourceDefinition): (boolean, string?)
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.SetSource(sourceId, definition)
	end,
	RemoveSource = function(sourceId: string): (boolean, string?)
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.RemoveSource(sourceId)
	end,
	SetContextEnabled = function(contextId: string, enabled: boolean): (boolean, string?)
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.SetContextEnabled(contextId, enabled)
	end,
	GetInput = function(inputId: string): Types.InputSnapshot?
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return nil
		end

		return owner.GetInput(inputId)
	end,
	GetContext = function(contextId: string): Types.ContextSnapshot?
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return nil
		end

		return owner.GetContext(contextId)
	end,
	GetEffectiveBindings = function(inputId: string): { [string]: Types.BindingSnapshot }?
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return nil
		end

		return owner.GetEffectiveBindings(inputId)
	end,
	BindActionLabel = function(inputId: string, label: InputActionLabel): (boolean, string?)
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.BindActionLabel(inputId, label)
	end,
	UnbindActionLabel = function(label: InputActionLabel): (boolean, string?)
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.UnbindActionLabel(label)
	end,
}

return table.freeze(facade)
