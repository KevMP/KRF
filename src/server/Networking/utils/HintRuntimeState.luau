--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.HintSenderRuntime? = nil
local State = {}

function State.Get(): Types.HintSenderRuntime?
	return current
end

function State.Install(runtime: Types.HintSenderRuntime?): ()
	current = runtime
end

return State
