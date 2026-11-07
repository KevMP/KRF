--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.ClientActionRequestRuntime? = nil
local State = {}

-- Framework-private handoff for I6; absent until a configured client reaches READY.
function State.Get(): Types.ClientActionRequestRuntime?
	return current
end

function State.Install(runtime: Types.ClientActionRequestRuntime?): ()
	current = runtime
end

return State
