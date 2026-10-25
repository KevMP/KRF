--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.ClientHintRuntime? = nil
local HintRuntimeState = {}

function HintRuntimeState.Get(): Types.ClientHintRuntime?
	return current
end

function HintRuntimeState.Install(runtime: Types.ClientHintRuntime?): ()
	current = runtime
end

return HintRuntimeState
