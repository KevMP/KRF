--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)
local current: Types.ClientHintRuntime? = nil
local received: SignalTypes.Signal<Types.HintReceived> = Signal.new()
local HintRuntimeState = { OnHintReceived = Signal.wrapEvent(received) }

function HintRuntimeState.Get(): Types.ClientHintRuntime?
	return current
end

function HintRuntimeState.Install(runtime: Types.ClientHintRuntime?): ()
	current = runtime
end

function HintRuntimeState.Notify(value: Types.HintReceived): ()
	received:Fire(value)
end

function HintRuntimeState.Disconnect(): ()
	received:DisconnectAll()
end

return HintRuntimeState
