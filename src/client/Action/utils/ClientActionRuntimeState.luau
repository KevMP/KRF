--!strict
local Types = require(script.Parent.Parent.types)
local current: Types.ClientActionOwner? = nil
local input: Types.ActionInputOwner? = nil
local State = {}

function State.Get(): Types.ClientActionOwner?
	return current
end

function State.Install(owner: Types.ClientActionOwner?): ()
	current = owner
end

function State.GetInput(): Types.ActionInputOwner?
	return input
end

function State.InstallInput(owner: Types.ActionInputOwner?): ()
	input = owner
end

return State
