--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)
local requests: SignalTypes.Signal<Types.ActionRequestEvent> = Signal.new()
local current: Types.ClientActionOwner? = nil
local input: Types.ActionInputOwner? = nil
local State = { OnActionRequest = Signal.wrapEvent(requests) }

-- I8 contract scaffold. The installed, generation-fenced observation bridge is
-- deliberately absent until the behavior tests are implemented.
function State.ObserveActionRequest(_observer: (Types.ActionRequestEvent) -> ()): () -> ()
	return function(): () end
end

-- Private boundary injection for the safe-integer exhaustion regression.
function State._SetObservationOrdinalForTests(_ordinal: number): () end

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
