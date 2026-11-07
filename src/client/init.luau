--!strict
local ClientTypes = require(script.types)
local SharedNetworkingTypes = require(script.Parent.shared.Networking.types)
local Constants = require(script.Parent.shared.Networking.utils.ProtocolConstants)
local ActorConstants = require(script.Parent.shared.Networking.utils.ActorProtocolConstants)
local CommandConstants = require(script.Parent.shared.Networking.utils.CommandConstants)
local ProtocolCodec = require(script.Parent.shared.Networking.ProtocolCodec)
local ManifestCompiler = require(script.Parent.shared.Networking.ManifestCompiler)
local Diagnostics = require(script.Networking.utils.NetworkingDiagnosticsState)
local SendMetrics = require(script.Parent.shared.Networking.utils.NetworkingSendMetrics)
local defaultDependencies: ClientTypes.Dependencies = require(script.Networking.utils.NativeClientDependencies)
local InputInstallation = require(script.Input.utils.InputInstallation)
local ActionInstallation = require(script.Action.utils.ClientActionInstallation)
local ActionRequestTypes = require(script.Parent.shared.ActionRequest.types)
local ActionRequestCatalog = require(script.Parent.shared.ActionRequest.ActionRequestCatalog)
local ActionRequestInstallation = require(script.ActionRequest.utils.ClientActionRequestInstallation)

export type StartupFailure = ClientTypes.StartupFailure

local Client = {} :: ClientTypes.Client
local attempted: boolean = false
local initialized: boolean = false
local readyProtocol: SharedNetworkingTypes.ClientProtocol? = nil
local injectedDependencies: ClientTypes.Dependencies? = nil
local shutdown: (() -> ())? = nil

local CONFIG_FIELDS: { [string]: boolean } = { actionRequestSchemas = true }

table.freeze(CONFIG_FIELDS)

-- Configuration is validated and compiled before any transport or diagnostics work.
local function prepare(config: any): (ActionRequestTypes.ActionRequestCatalog?, StartupFailure?)
	if config == nil then
		return nil, nil
	elseif type(config) ~= "table" then
		return nil, { system = "Client", reason = "ClientConfigInvalid" }
	end

	for field: any in next, config do
		if type(field) ~= "string" or not CONFIG_FIELDS[field] then
			return nil, { system = "Client", reason = "ClientConfigFieldUnknown" }
		end
	end

	local schemas: any = rawget(config, "actionRequestSchemas")

	if schemas == nil then
		return nil, nil
	end

	local catalog: ActionRequestTypes.ActionRequestCatalog?, reason: string? = ActionRequestCatalog.Compile(schemas)

	if catalog == nil then
		return nil, { system = "ActionRequest", reason = reason :: string }
	end

	return catalog, nil
end

local function dispose(callback: (() -> ())?): ()
	if callback == nil then
		return
	end

	local completed: boolean, reason: any = pcall(callback)

	if not completed then
		warn("[Networking] client cleanup failed: " .. tostring(reason))
	end
end

function Client.Init(config: ClientTypes.ClientInitConfig?): (boolean, StartupFailure?)
	if attempted then
		return false, { system = "Client", reason = "ClientInitAlreadyAttempted" }
	end

	attempted = true
	local requestCatalog: ActionRequestTypes.ActionRequestCatalog?, configFailure: StartupFailure? = prepare(config)

	if configFailure ~= nil then
		return false, configFailure
	end

	local diagnosticOwner = Diagnostics.Start()
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
	local cleanupInput: (() -> ())? = nil
	local cleanupActions: (() -> ())? = nil
	local cleanupActionRequests: (() -> ())? = nil
	local protocol: SharedNetworkingTypes.ClientProtocol? = nil
	local receiveActors: ((any) -> ())? = nil

	local function cancelTimer(): ()
		local cancel: (() -> ())? = cancelTimeout
		cancelTimeout = nil
		dispose(cancel)
	end

	local function cleanup(): ()
		local stopActions: (() -> ())? = cleanupActions
		cleanupActions = nil
		dispose(stopActions)
		local stopInput: (() -> ())? = cleanupInput
		cleanupInput = nil
		dispose(stopInput)
		receiveActors = nil
		cancelTimer()
		local listener: (() -> ())? = disconnect
		disconnect = nil
		dispose(listener)
		local consumers: (() -> ())? = cleanupConsumers
		cleanupConsumers = nil
		dispose(consumers)
		-- After the command runtime, so its closing Unknown outcomes still correlate.
		local stopActionRequests: (() -> ())? = cleanupActionRequests
		cleanupActionRequests = nil
		dispose(stopActionRequests)
		protocol = nil
		Diagnostics.Stop(diagnosticOwner)
	end

	local function finish(accepted: boolean, reason: string?, system: string?): ()
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
			failure = { system = system or "Networking", reason = reason :: string }
			cleanup()
		end

		if waitingThread ~= nil then
			local waiter: thread = waitingThread :: thread
			waitingThread = nil
			dependencies.Resume(waiter)
		end
	end

	local function terminate(reason: string): ()
		initialized = false
		readyProtocol = nil

		if finished then
			success = false
			cleanup()
		else
			finish(false, reason)
		end
	end

	shutdown = function(): ()
		terminate("ClientReset")
	end

	local discovered: boolean, endpoint: ClientTypes.ClientTransport?, discoveryReason: string? =
		pcall(dependencies.DiscoverTransport, deadline)

	if not discovered then
		finish(false, "StartupInternalFailure:" .. tostring(endpoint))
	elseif endpoint == nil then
		finish(false, discoveryReason or "TransportUnavailable")
	else
		local transport: ClientTypes.ClientTransport = endpoint

		local function sendReliable(payload: buffer): ()
			SendMetrics.Record(diagnosticOwner, true, payload)
			transport.SendReliable(payload)
		end

		local function receive(payload: any, ...: any): ()
			if finished then
				if
					success
					and receiveActors ~= nil
					and select("#", ...) == 0
					and typeof(payload) == "buffer"
					and buffer.len(payload) > 0
					and (
						buffer.readu8(payload, 0) == ActorConstants.PACKET_KIND
						or buffer.readu8(payload, 0) == CommandConstants.RESULT_KIND
					)
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
					SendMetrics.Wrap(diagnosticOwner, true, transport.SendReliable),
					function(): boolean
						return initialized and success
					end,
					function(): ()
						terminate("ReliableConsumerFailed")
					end,
					if transport.SendUnreliable ~= nil
						then SendMetrics.Wrap(diagnosticOwner, false, transport.SendUnreliable)
						else nil,
					transport.ConnectUnreliable
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

				cleanupInput = InputInstallation.Install(function(): boolean
					return initialized and success
				end)

				cleanupActions = ActionInstallation.Install(function(): boolean
					return initialized and success
				end)

				if requestCatalog ~= nil then
					local stopRequests: (() -> ())?, requestReason: string? =
						ActionRequestInstallation.Install(requestCatalog, reconstructed)

					if stopRequests == nil then
						finish(false, requestReason, "ActionRequest")

						return
					end

					cleanupActionRequests = stopRequests
				end

				state = "AwaitAck"
				local ready: buffer?, readyReason: string? = ProtocolCodec.Encode({ kind = "Ready" })
				assert(ready ~= nil, readyReason)
				sendReliable(ready)
			end
		end

		local connected: boolean, connectReason: any = pcall(function(): ()
			disconnect = transport.ConnectReliable(function(payload: any, ...: any): ()
				local completed: boolean, reason: any = pcall(receive, payload, ...)

				if not completed then
					terminate("StartupInternalFailure:" .. tostring(reason))
				end
			end)

			cancelTimeout = dependencies.ScheduleTimeout(math.max(0, deadline - dependencies.Now()), function(): ()
				finish(false, "HandshakeTimeout")
			end)

			local hello: buffer?, reason: string? =
				ProtocolCodec.Encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION })

			assert(hello ~= nil, reason)
			sendReliable(hello)
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
