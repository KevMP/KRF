--!strict
local Types = require(script.Parent.types)
local State = require(script.Parent.utils.InputRuntimeState)
local Observers = require(script.Parent.Parent.Parent.shared.Signal.PrivateObservers)

local facade: Types.InputRuntime = {
	OnSequenceMatched = State.OnSequenceMatched,
	OnRecognizerMatched = State.OnRecognizerMatched,
	GetSequence = function(sequenceId: string): Types.SequenceSnapshot?
		local owner: Types.InputOwner? = State.Get()

		return if owner == nil then nil else owner.GetSequence(sequenceId)
	end,
	GetRecognizer = function(recognizerId: string): Types.RecognizerSnapshot?
		local owner: Types.InputOwner? = State.Get()

		return if owner == nil then nil else owner.GetRecognizer(recognizerId)
	end,
	OnGesture = State.OnGesture,
	GetGestures = function(inputId: string): { [Types.GestureKind]: Types.GestureSnapshot }?
		local owner: Types.InputOwner? = State.Get()

		return if owner == nil then nil else owner.GetGestures(inputId)
	end,
	OnInput = State.OnInput,
	SetSource = function(sourceId: string, definition: Types.InputSourceDefinition): (boolean, string?)
		Observers.CheckReentry()
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.SetSource(sourceId, definition)
	end,
	RemoveSource = function(sourceId: string): (boolean, string?)
		Observers.CheckReentry()
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.RemoveSource(sourceId)
	end,
	SetContextEnabled = function(contextId: string, enabled: boolean): (boolean, string?)
		Observers.CheckReentry()
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
		Observers.CheckReentry()
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.BindActionLabel(inputId, label)
	end,
	UnbindActionLabel = function(label: InputActionLabel): (boolean, string?)
		Observers.CheckReentry()
		local owner: Types.InputOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.UnbindActionLabel(label)
	end,
}

return table.freeze(facade)
