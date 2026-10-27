--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ClientTypes = require(script.Parent.Parent.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Transport = require(script.Parent.Parent.Parent.Parent.shared.Networking.Transport)

local Installation = require(script.Parent.ClientConsumerInstallation)

local dependencies: ClientTypes.Dependencies

dependencies = {
	Now = os.clock,
	ObserveStep = function(callback: () -> ()): () -> ()
		local connection = RunService.Heartbeat:Connect(function(_deltaTime: number): ()
			callback()
		end)

		return function(): ()
			connection:Disconnect()
		end
	end,
	Resume = function(waitingThread: thread): ()
		task.defer(waitingThread)
	end,
	DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
		local lastReason: string = "TransportUnavailable"

		repeat
			local transports: SharedNetworkingTypes.OwnedTransport?, reason: string? =
				Transport.Locate(ReplicatedStorage)

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
					ConnectUnreliable = function(callback: (any, ...any) -> ()): () -> ()
						local connection = transports.unreliable.OnClientEvent:Connect(callback)

						return function(): ()
							connection:Disconnect()
						end
					end,
					SendUnreliable = function(payload: buffer): ()
						transports.unreliable:FireServer(payload)
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
	InstallConsumers = function(
		protocol: SharedNetworkingTypes.ClientProtocol,
		manifest: SharedNetworkingTypes.ProtocolManifest?,
		installActorReceiver: (((any) -> ()) -> ())?,
		sendReliable: ((buffer) -> ())?,
		isReady: (() -> boolean)?,
		onTerminalFailure: (() -> ())?,
		sendUnreliable: ((buffer) -> ())?,
		connectUnreliable: ClientTypes.ClientUnreliableObserver?
	): (boolean, string?, (() -> ())?)
		return Installation.Install(protocol, manifest, {
			Now = dependencies.Now,
			ScheduleTimeout = dependencies.ScheduleTimeout,
			ObserveStep = dependencies.ObserveStep,
			installActorReceiver = installActorReceiver,
			sendReliable = sendReliable,
			isReady = isReady,
			onTerminalFailure = onTerminalFailure,
			sendUnreliable = sendUnreliable,
			connectUnreliable = connectUnreliable,
		})
	end,
}

return dependencies :: ClientTypes.Dependencies
