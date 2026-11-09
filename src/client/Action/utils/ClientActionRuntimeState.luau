--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)
local requests: SignalTypes.Signal<Types.ActionRequestEvent> = Signal.new()
local current: Types.ClientActionOwner? = nil
local input: Types.ActionInputOwner? = nil
local observations: Types.ActionObservationOwner? = nil
local State = { OnActionRequest = Signal.wrapEvent(requests) }

function State.ObserveActionRequest(observer: (Types.ActionRequestEvent) -> ()): () -> ()
	return if observations == nil then function() end else observations.Observe(observer)
end

-- Private boundary injection for the safe-integer exhaustion regression.
function State._SetObservationOrdinalForTests(ordinal: number): ()
	if observations ~= nil then
		observations.SetOrdinalForTests(ordinal)
	end
end

function State.CheckObservationReentry(): ()
	if observations ~= nil then
		observations.Reentered()
	end
end

function State.InstallObservations(owner: Types.ActionObservationOwner?): ()
	observations = owner

	if owner ~= nil then
		owner.SetInput(input)
	end
end

function State.GetObservations(): Types.ActionObservationOwner?
	return observations
end

function State.NotifyActionRequest(fact: Types.ActionRequestEvent): ()
	requests:Fire(fact)
end

function State.DisconnectActionRequests(): ()
	requests:DisconnectAll()
end

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

	if observations ~= nil then
		observations.SetInput(owner)
	end
end

return State
