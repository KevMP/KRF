--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)

local results: SignalTypes.Signal<Types.CommandResult> = Signal.new()
local uncertain: SignalTypes.Signal<Types.CommandResult> = Signal.new()
local current: Types.ClientCommandRuntime? = nil

local State = {
	OnCommandResult = Signal.wrapEvent(results),
	OnCommandUncertain = Signal.wrapEvent(uncertain),
}

function State.Get(): Types.ClientCommandRuntime?
	return current
end

function State.Install(runtime: Types.ClientCommandRuntime?): ()
	current = runtime
end

function State.Notify(result: Types.CommandResult): ()
	if result.status == "Unknown" then
		uncertain:Fire(result)
	else
		results:Fire(result)
	end
end

function State.Disconnect(): ()
	results:DisconnectAll()
	uncertain:DisconnectAll()
end

return State
