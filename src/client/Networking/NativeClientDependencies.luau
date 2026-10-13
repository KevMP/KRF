--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientTypes = require(script.Parent.Parent.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local Transport = require(script.Parent.Parent.Parent.shared.Networking.Transport)

local dependencies: ClientTypes.Dependencies = {
	Now = os.clock,
	Resume = function(waitingThread: thread): ()
		task.defer(waitingThread)
	end,
	DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
		local lastReason: string = "TransportUnavailable"
		repeat
			local transports: ProtocolTypes.OwnedTransport?, reason: string? = Transport.Locate(ReplicatedStorage)
			if transports ~= nil then
				local reliable: RemoteEvent = transports.reliable
				return {
					ConnectReliable = function(callback: (any, ...any) -> ()): () -> ()
						local connection: RBXScriptConnection = reliable.OnClientEvent:Connect(callback)
						return function(): ()
							connection:Disconnect()
						end
					end,
					SendReliable = function(payload: buffer): ()
						reliable:FireServer(payload)
					end,
				},
					nil
			end
			lastReason = reason :: string
			local remaining: number = deadline - os.clock()
			if remaining <= 0 then
				break
			end
			task.wait(math.min(0.05, remaining))
		until false
		return nil, lastReason
	end,
	ScheduleTimeout = function(seconds: number, callback: () -> ()): () -> ()
		local fired: boolean = false
		local timer: thread = task.delay(seconds, function(): ()
			fired = true
			callback()
		end)
		return function(): ()
			if not fired and coroutine.status(timer) ~= "dead" then
				task.cancel(timer)
			end
		end
	end,
	-- Framework-only pre-READY phase. No Actor or command consumers exist in N2.
	InstallConsumers = function(_protocol: ProtocolTypes.ClientProtocol): (boolean, string?, (() -> ())?)
		return true, nil, nil
	end,
}

return dependencies
