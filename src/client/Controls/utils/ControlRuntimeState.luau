--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.ControlOwner? = nil
local State = {}

function State.Get(): Types.ControlOwner?
	return current
end

function State.Install(owner: Types.ControlOwner?): ()
	current = owner
end

return State
