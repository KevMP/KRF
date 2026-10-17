--!strict
local ClientTypes = require(script.types)
local SharedNetworkingTypes = require(script.Parent.shared.Networking.types)
local Constants = require(script.Parent.shared.Networking.utils.ProtocolConstants)
local ActorConstants = require(script.Parent.shared.Networking.utils.ActorProtocolConstants)
local ProtocolCodec = require(script.Parent.shared.Networking.ProtocolCodec)
local ManifestCompiler = require(script.Parent.shared.Networking.ManifestCompiler)
local defaultDependencies: ClientTypes.Dependencies = require(script.Networking.utils.NativeClientDependencies)

export type StartupFailure = ClientTypes.StartupFailure

local Client = {} :: ClientTypes.Client
local attempted: boolean = false
local initialized: boolean = false
local readyProtocol: SharedNetworkingTypes.ClientProtocol? = nil
local injectedDependencies: ClientTypes.Dependencies? = nil
local shutdown: (() -> ())? = nil

local function dispose(callback: (() -> ())?): ()
	if callback == nil then
		return
	end
	local completed: boolean, reason: any = pcall(callback)
	if not completed then
		warn("[Networking] client cleanup failed: " .. tostring(reason))
	end
end

function Client.Init(): (boolean, StartupFailure?)
	if attempted then
		return false, { system = "Client", reason = "ClientInitAlreadyAttempted" }
	end
	attempted = true
	local dependencies: ClientTypes.Dependencies = injectedDependencies or defaultDependencies
	local deadline: number = dependencies.Now() + Constants.INIT_TIMEOUT_SECONDS
	local state: "AwaitBootstrap" | "AwaitAck" = "AwaitBootstrap"
	local finished: boolean = false
	local success: boolean = false
	local failure: StartupFailure? = nil
	local waitingThread: thread? = nil
	local disconnect: (() -> ())? = nil
	local cancelTimeout: (() -> ())? = nil
	local cleanupConsumers: (() -> ())? = nil
	local protocol: SharedNetworkingTypes.ClientProtocol? = nil
	local receiveActors: ((any) -> ())? = nil

	local function cancelTimer(): ()
		local cancel: (() -> ())? = cancelTimeout
		cancelTimeout = nil
		dispose(cancel)
	end

	local function cleanup(): ()
		receiveActors = nil
		cancelTimer()
		local listener: (() -> ())? = disconnect
		disconnect = nil
		dispose(listener)
		local consumers: (() -> ())? = cleanupConsumers
		cleanupConsumers = nil
		dispose(consumers)
		protocol = nil
	end

	local function finish(accepted: boolean, reason: string?): ()
		if finished then
			return
		end
		finished = true
		success = accepted
		if accepted then
			readyProtocol = protocol
			initialized = true
			cancelTimer()
		else
			failure = { system = "Networking", reason = reason :: string }
			cleanup()
		end
		if waitingThread ~= nil then
			local waiter: thread = waitingThread :: thread
			waitingThread = nil
			dependencies.Resume(waiter)
		end
	end

	shutdown = function(): ()
		finish(false, "ClientReset")
		cleanup()
	end
	local discovered: boolean, endpoint: ClientTypes.ClientTransport?, discoveryReason: string? =
		pcall(dependencies.DiscoverTransport, deadline)
	if not discovered then
		finish(false, "StartupInternalFailure:" .. tostring(endpoint))
	elseif endpoint == nil then
		finish(false, discoveryReason or "TransportUnavailable")
	else
		local transport: ClientTypes.ClientTransport = endpoint
		local function receive(payload: any, ...: any): ()
			if finished then
				if
					success
					and receiveActors ~= nil
					and select("#", ...) == 0
					and typeof(payload) == "buffer"
					and buffer.len(payload) > 0
					and buffer.readu8(payload, 0) == ActorConstants.PACKET_KIND
				then
					receiveActors(payload)
				end
				return
			end
			if select("#", ...) ~= 0 then
				finish(false, if state == "AwaitAck" then "ReadyRejected" else "MalformedBootstrap")
				return
			end
			local message: SharedNetworkingTypes.ProtocolMessage?, reason: string? = ProtocolCodec.Decode(payload)
			if message == nil then
				if reason == "UnknownMessageKind" then
					return
				end
				finish(
					false,
					if reason == "ProtocolMismatch"
							or reason == "UnsupportedSchema"
							or reason == "BootstrapTooLarge"
						then reason
						else if state == "AwaitAck" then "ReadyRejected" else "MalformedBootstrap"
				)
				return
			end
			if message.kind == "Reject" then
				finish(false, if message.reason == "MalformedPacket" then "MalformedBootstrap" else message.reason)
			elseif message.kind == "ReadyAck" then
				if state ~= "AwaitAck" then
					finish(false, "ReadyRejected")
				else
					finish(true, nil)
				end
			elseif message.kind == "Bootstrap" and state == "AwaitBootstrap" then
				if message.manifest.version ~= Constants.PROTOCOL_VERSION then
					finish(false, "ProtocolMismatch")
					return
				end
				local reconstructed: SharedNetworkingTypes.ClientProtocol?, compileReason: string? =
					ManifestCompiler.Reconstruct(message.manifest)
				if reconstructed == nil then
					finish(false, compileReason or "UnsupportedSchema")
					return
				end
				protocol = reconstructed
				local installer: thread = coroutine.create(dependencies.InstallConsumers)
				local completed: boolean, installed: any, installReason: string?, consumerCleanup: (() -> ())? = coroutine.resume(
					installer,
					reconstructed,
					message.manifest,
					function(receiver: (any) -> ())
						receiveActors = receiver
					end,
					transport.SendReliable
				)
				if coroutine.status(installer) ~= "dead" then
					coroutine.close(installer)
					completed = false
					installed = "Yielded"
				end
				cleanupConsumers = consumerCleanup
				if not completed then
					finish(false, "StartupInternalFailure:" .. tostring(installed))
					return
				end
				if installed ~= true then
					finish(false, installReason or "InternalConsumerInitializationFailed")
					return
				end
				state = "AwaitAck"
				local ready: buffer?, readyReason: string? = ProtocolCodec.Encode({ kind = "Ready" })
				assert(ready ~= nil, readyReason)
				transport.SendReliable(ready)
			end
		end
		local connected: boolean, connectReason: any = pcall(function(): ()
			disconnect = transport.ConnectReliable(function(payload: any, ...: any): ()
				local completed: boolean, reason: any = pcall(receive, payload, ...)
				if not completed then
					finish(false, "StartupInternalFailure:" .. tostring(reason))
				end
			end)
			cancelTimeout = dependencies.ScheduleTimeout(math.max(0, deadline - dependencies.Now()), function(): ()
				finish(false, "HandshakeTimeout")
			end)
			local hello: buffer?, reason: string? =
				ProtocolCodec.Encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION })
			assert(hello ~= nil, reason)
			transport.SendReliable(hello)
		end)
		if not connected then
			finish(false, "StartupInternalFailure:" .. tostring(connectReason))
		end
	end
	if not finished then
		waitingThread = coroutine.running()
		coroutine.yield()
	end
	return success, failure
end

function Client._IsInitialized(): boolean
	return initialized and readyProtocol ~= nil
end

function Client._SetDependenciesForTests(dependencies: ClientTypes.Dependencies): ()
	assert(not attempted, "ClientInitAlreadyAttempted")
	injectedDependencies = dependencies
end

function Client._ResetForTests(): ()
	if shutdown ~= nil then
		shutdown()
		shutdown = nil
	end
	attempted = false
	initialized = false
	readyProtocol = nil
	injectedDependencies = nil
end

return Client
