--!strict
local Types = require(script.Parent.Parent.types)
local Metrics = require(script.Parent.NetworkingMetrics)
local ActorConstants = require(script.Parent.ActorProtocolConstants)
local HintConstants = require(script.Parent.HintConstants)
local CommandConstants = require(script.Parent.CommandConstants)
local SendMetrics = {}

function SendMetrics.Record(owner: Types.DiagnosticCollector?, reliable: boolean, payload: buffer): ()
	if owner == nil then
		return
	end

	local bytes = buffer.len(payload)
	local records = 0

	-- Outbound buffers are already encoded by KRF. Read only fixed envelope
	-- metadata; never decode/clone payloads solely for instrumentation.
	if bytes > 0 then
		local kind = buffer.readu8(payload, 0)

		if bytes >= 9 and (kind == ActorConstants.PACKET_KIND or kind == HintConstants.PACKET_KIND) then
			records = buffer.readu32(payload, 5)
		elseif
			kind == CommandConstants.REQUEST_KIND
			or kind == CommandConstants.RESULT_KIND
			or kind == ActorConstants.RESYNC_PACKET_KIND
		then
			records = 1
		end
	end

	Metrics.Count(owner, if reliable then "reliableSendAttempts" else "unreliableSendAttempts", 1)
	Metrics.Count(owner, if reliable then "reliableEncodedBytes" else "unreliableEncodedBytes", bytes)
	Metrics.Count(owner, if reliable then "reliableLogicalRecords" else "unreliableLogicalRecords", records)
end

-- Consumers retain the transport function selected at installation, while startup
-- may still consult its adapter dynamically. Instrumentation preserves both.
function SendMetrics.Wrap(owner: Types.DiagnosticCollector?, reliable: boolean, send: (buffer) -> ()): (buffer) -> ()
	return function(payload: buffer): ()
		SendMetrics.Record(owner, reliable, payload)
		send(payload)
	end
end

return SendMetrics
