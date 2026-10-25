--!strict
local Types = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local State = {}
local current: Types.DiagnosticCollector? = nil

function State.Start(): Types.DiagnosticCollector
	local owner = Metrics.new("Client", nil)
	current = owner

	return owner
end

function State.Get(): Types.DiagnosticCollector?
	return current
end

function State.Stop(expected: Types.DiagnosticCollector?): ()
	if expected ~= nil and current ~= expected then
		return
	end

	current = nil
end

return State
