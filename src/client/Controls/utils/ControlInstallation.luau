--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local ActionTypes = require(script.Parent.Parent.Parent.Action.types)
local InputState = require(script.Parent.Parent.Parent.Input.utils.InputRuntimeState)
local ActionState = require(script.Parent.Parent.Parent.Action.utils.ClientActionRuntimeState)
local State = require(script.Parent.ControlRuntimeState)
local Native = require(script.Parent.NativeControlLifecycle)
local Owner = require(script.Parent.Parent.ControlOwner)

local Installation = {}

function Installation.Install(isReady: () -> boolean): () -> ()
	local input: InputTypes.InputOwner = assert(InputState.Get(), "InputOwnerUnavailable")
	local actions: ActionTypes.ClientActionOwner = assert(ActionState.Get(), "ActionOwnerUnavailable")
	local owner: Types.ControlOwner = Owner.new(input, actions, isReady)
	local active: boolean = true
	local stopNative: (() -> ())? = nil
	local stopCommit: (() -> ())? = nil

	local function stop(): ()
		if not active then
			return
		end

		active = false

		if stopNative ~= nil then
			stopNative()
		end

		if stopCommit ~= nil then
			stopCommit()
		end

		owner.Destroy()

		if State.Get() == owner then
			State.Install(nil)
		end
	end

	local installed: boolean, reason: unknown = pcall(function(): ()
		stopNative = Native.Observe(function(event): ()
			if active and isReady() then
				owner.OnLifecycle(event)
			end
		end)

		stopCommit = input.ObserveConfigurationCommit(function(): ()
			if input.GetMutationStatus(true) == "InputRuntimeFaulted" then
				assert(stopNative, "Expected installed native subscription")()
			end
		end)
	end)

	if not installed then
		stop()
		error(reason, 0)
	end

	State.Install(owner)

	return stop
end

return Installation
