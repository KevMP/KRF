--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)

local input: SignalTypes.Signal<Types.SemanticInputEvent> = Signal.new()
local current: Types.InputOwner? = nil
local State = { OnInput = Signal.wrapEvent(input) }

function State.Get(): Types.InputOwner?
	return current
end

function State.Install(owner: Types.InputOwner?): ()
	current = owner
end

function State.Notify(event: Types.SemanticInputEvent): ()
	input:Fire(event)
end

function State.Disconnect(): ()
	input:DisconnectAll()
end

return State
