--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.ClientActionOwner? = nil
local State = {}

function State.Get(): Types.ClientActionOwner?
	return current
end

function State.Install(owner: Types.ClientActionOwner?): ()
	current = owner
end

return State
