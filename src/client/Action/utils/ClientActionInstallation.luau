--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local InputState = require(script.Parent.Parent.Parent.Input.utils.InputRuntimeState)
local State = require(script.Parent.ClientActionRuntimeState)
local Owner = require(script.Parent.Parent.ClientActionOwner)
local Installation = {}

function Installation.Install(isReady: () -> boolean): () -> ()
	local input: InputTypes.InputOwner = assert(InputState.Get(), "InputOwnerUnavailable")

	local previous: Types.ClientActionOwner? = State.Get()

	if previous ~= nil then
		previous.Destroy()
	end

	local owner: Types.ClientActionOwner? = nil

	owner = Owner.new({
		OnDestroyed = function(): ()
			if State.Get() == owner then
				State.Install(nil)
			end
		end,
		Input = input,
		IsReady = isReady,
		-- I4 selects local routes only. I5/I6 own authenticated Start admission.
		Sink = function() end,
		ReportFault = function(reason: string): ()
			if reason ~= "ResolvedNoAction" then
				warn("[ActionRoutes] " .. reason)
			end
		end,
	})

	State.Install(owner)
	local installed: Types.ClientActionOwner = owner
	local active: boolean = true

	return function(): ()
		if not active then
			return
		end

		active = false

		if State.Get() == installed then
			State.Install(nil)
		end

		installed.Destroy()
	end
end

return Installation
