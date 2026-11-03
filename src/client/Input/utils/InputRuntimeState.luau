--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)

local input: SignalTypes.Signal<Types.SemanticInputEvent> = Signal.new()
local gesture: SignalTypes.Signal<Types.GestureEvent> = Signal.new()
local sequence: SignalTypes.Signal<Types.SequenceMatchEvent> = Signal.new()
local recognizer: SignalTypes.Signal<Types.CustomRecognitionEvent> = Signal.new()
local current: Types.InputOwner? = nil

local State = {
	OnInput = Signal.wrapEvent(input),
	OnGesture = Signal.wrapEvent(gesture),
	OnSequenceMatched = Signal.wrapEvent(sequence),
	OnRecognizerMatched = Signal.wrapEvent(recognizer),
}

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
	gesture:DisconnectAll()
	sequence:DisconnectAll()
	recognizer:DisconnectAll()
end

function State.NotifyGesture(event: Types.GestureEvent): ()
	gesture:Fire(event)
end

function State.NotifySequence(event: Types.SequenceMatchEvent): ()
	sequence:Fire(event)
end

function State.NotifyRecognizer(event: Types.CustomRecognitionEvent): ()
	recognizer:Fire(event)
end

return State
