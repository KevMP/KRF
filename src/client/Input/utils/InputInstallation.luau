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
		PublishSequence = function(event: Types.SequenceMatchEvent): ()
			if active and State.Get() == owner then
				State.NotifySequence(event)
			end
		end,
		PublishRecognizer = function(event: Types.CustomRecognitionEvent): ()
			if active and State.Get() == owner then
				State.NotifyRecognizer(event)
			end
		end,
		PublishGesture = function(event: Types.GestureEvent): ()
			if active and State.Get() == owner then
				State.NotifyGesture(event)
			end
		end,
		ReportFault = function(reason: string): ()
			if reason == "InputRuntimeFaulted" then
				State.Disconnect()
			end

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
