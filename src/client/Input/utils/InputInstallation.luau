--!strict
local Types = require(script.Parent.Parent.types)
local Owner = require(script.Parent.Parent.InputOwner)
local Native = require(script.Parent.NativeInputAdapter)
local State = require(script.Parent.InputRuntimeState)

local Installation = {}

function Installation.Install(isReady: () -> boolean): () -> ()
	local active: boolean = true
	local owner: Types.InputOwner? = nil

	owner = Owner.new({
		Native = Native.new(),
		Now = os.clock,
		IsReady = isReady,
		Publish = function(event: Types.SemanticInputEvent): ()
			if active and State.Get() == owner then
				State.Notify(event)
			end
		end,
		ReportFault = function(reason: string): ()
			warn("[Input] " .. reason)
		end,
	})

	State.Install(owner)

	return function(): ()
		if not active then
			return
		end

		active = false
		State.Install(nil)
		State.Disconnect()
		assert(owner ~= nil, "Expected initialized input state")
		owner.Destroy()
	end
end

return Installation
