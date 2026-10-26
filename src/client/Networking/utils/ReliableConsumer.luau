--!strict
local Types = require(script.Parent.Parent.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local ActorConstants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

local ReliableConsumer = {}

function ReliableConsumer.new(
	actors: (any) -> (),
	commands: Types.ClientCommandRuntime,
	fault: () -> ()
): ((any) -> (), () -> ())
	local diagnostics = Diagnostics.Get()
	local active: boolean = true
	local paused: boolean = false
	local queue: { buffer } = {}
	local bytes: number = 0
	local continuation: thread? = nil
	local receive: (any) -> ()

	local function consume(payload: buffer): ()
		if buffer.readu8(payload, 0) == Constants.RESULT_KIND then
			if commands:Handle(payload) and active then
				-- SignalModule starts listeners through the scheduler. Let those
				-- callbacks begin before applying the next Actor publication.
				paused = true

				continuation = task.defer(function(): ()
					continuation = nil
					paused = false

					while active and not paused and #queue > 0 do
						local nextPayload: buffer = table.remove(queue, 1) :: buffer
						bytes -= buffer.len(nextPayload)
						Metrics.Adjust(diagnostics, "clientReliableDeferredRecords", -1)
						Metrics.Adjust(diagnostics, "clientReliableDeferredBytes", -buffer.len(nextPayload))
						consume(nextPayload)
					end
				end)
			end
		elseif buffer.readu8(payload, 0) == ActorConstants.PACKET_KIND then
			actors(payload)
		end
	end

	local function cleanup(): ()
		active = false

		if continuation ~= nil then
			task.cancel(continuation)
			continuation = nil
		end

		Metrics.Count(diagnostics, "clientReliableDeferredDropped", #queue)
		Metrics.Set(diagnostics, "clientReliableDeferredRecords", 0)
		Metrics.Set(diagnostics, "clientReliableDeferredBytes", 0)
		table.clear(queue)
		bytes = 0
	end

	receive = function(payload: any): ()
		if not active or typeof(payload) ~= "buffer" or buffer.len(payload) == 0 then
			return
		end

		if paused then
			if #queue >= Constants.MAX_FENCED_RECORDS or bytes + buffer.len(payload) > Constants.MAX_FENCED_BYTES then
				Metrics.Count(diagnostics, "clientReliableDeferredDropped", 1)
				cleanup()
				fault()

				return
			end

			table.insert(queue, payload)
			bytes += buffer.len(payload)
			Metrics.Count(diagnostics, "clientReliableDeferredAdmitted", 1)
			Metrics.Adjust(diagnostics, "clientReliableDeferredRecords", 1)
			Metrics.Adjust(diagnostics, "clientReliableDeferredBytes", buffer.len(payload))
		else
			consume(payload)
		end
	end

	return receive, cleanup
end

return ReliableConsumer
