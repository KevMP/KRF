--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ClientTypes = require(script.Parent.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Transport = require(script.Parent.Parent.Parent.Parent.shared.Networking.Transport)
local Types = require(script.Parent.Parent.types)
local Stream = require(script.Parent.Parent.ActorStreamRuntime)
local Views = require(script.Parent.Parent.ActorViewRuntime)
local Discovery = require(script.Parent.ActorModelDiscovery)
local Consumer = require(script.Parent.ActorStreamConsumer)
local Codec = require(script.Parent.Parent.Parent.Parent.shared.Networking.ActorStreamCodec)
local SchemaCompiler = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)
local Commands = require(script.Parent.Parent.ClientCommandRuntime)
local CommandState = require(script.Parent.CommandRuntimeState)
local ReliableConsumer = require(script.Parent.ReliableConsumer)
local Hints = require(script.Parent.Parent.ClientHintRuntime)
local HintReceiver = require(script.Parent.HintReceiver)
local HintState = require(script.Parent.HintRuntimeState)
local ViewRegistry = require(script.Parent.Parent.Parent.Actor.ActorViewRegistry)

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
		assert(manifest ~= nil and installActorReceiver ~= nil, "ActorInstallationMissing")
		local schemas: SharedNetworkingTypes.ActorSchemaCatalog = {}

		for _, domain: SharedNetworkingTypes.ManifestDomain in manifest.domains do
			local schema: SharedNetworkingTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(domain.state)
			assert(schema ~= nil, reason)
			schemas[domain.id] = schema
		end

		local codec: SharedNetworkingTypes.ActorStreamCodec = Codec.Compile(protocol, schemas)
		local discovery: Types.ActorModelDiscoveryAdapter = Discovery.new()
		local runtime: Types.ActorStreamRuntime? = nil
		local views: Types.ActorViewRuntime? = nil
		local active: boolean = true
		local commands: Types.ClientCommandRuntime? = nil
		local stopReceiver: (() -> ())? = nil
		local hints: Types.ClientHintRuntime? = nil
		local hintReceiver: Types.HintReceiverRuntime? = nil
		local stopUnreliable: (() -> ())? = nil
		local stopHints: (() -> ())? = nil
		local removedHintActor: SignalTypes.Connection? = nil

		local function cleanup(): ()
			if not active then
				return
			end

			active = false
			HintState.Install(nil)
			HintState.Disconnect()

			if stopUnreliable ~= nil then
				stopUnreliable()
				stopUnreliable = nil
			end

			if hintReceiver ~= nil then
				hintReceiver:Destroy()
				hintReceiver = nil
			end

			if stopHints ~= nil then
				stopHints()
				stopHints = nil
			end

			if removedHintActor ~= nil then
				removedHintActor:Disconnect()
				removedHintActor = nil
			end

			if hints ~= nil then
				hints:Destroy()
				hints = nil
			end

			if stopReceiver ~= nil then
				stopReceiver()
				stopReceiver = nil
			end

			CommandState.Install(nil)

			if commands ~= nil then
				commands:Destroy()
				commands = nil
			end

			CommandState.Disconnect()

			if runtime ~= nil then
				runtime:Destroy()
			end

			if views ~= nil then
				views:Destroy()
			end

			discovery.Destroy()
		end

		local success: boolean, reason: any = pcall(function()
			local consumer: Types.ActorStreamConsumer? = Consumer.Get()

			if consumer == nil then
				assert(sendReliable ~= nil, "ActorReliableEndpointMissing")

				local created: Types.ActorViewRuntime = Views.new(protocol, schemas, {
					Now = dependencies.Now,
					ScheduleTimeout = dependencies.ScheduleTimeout,
					SendReliable = sendReliable,
					ReportFault = function(fault: Types.ActorViewFault)
						warn("[Networking] ActorView fault actorId=" .. fault.actorId .. " reason=" .. fault.reason)
					end,
				})

				views = created
				consumer = created.consumer
			end

			local created: Types.ActorStreamRuntime = Stream.new(codec, consumer, discovery, {
				maxBaselineBytes = Constants.MAX_BASELINE_BYTES,
				maxPendingBaselines = Constants.MAX_PENDING_BASELINES,
				ReportFault = function(fault: string)
					warn("[Networking] Actor stream fault: " .. fault)
				end,
			})

			runtime = created
			assert(sendReliable ~= nil, "CommandReliableEndpointMissing")

			local commandRuntime: Types.ClientCommandRuntime = Commands.new(protocol, created, {
				IsReady = isReady or function(): boolean
					return false
				end,
				SendReliable = sendReliable,
				ScheduleTimeout = dependencies.ScheduleTimeout,
			})

			commands = commandRuntime
			CommandState.Install(commandRuntime)
			local hasC2S, hasS2C = false, false

			for _, hint in protocol.hintsById or {} do
				if hint.direction == "ClientToServer" then
					hasC2S = true
				else
					hasS2C = true
				end
			end

			if hasC2S then
				assert(sendUnreliable ~= nil and isReady ~= nil, "HintUnreliableEndpointMissing")

				local hintRuntime = Hints.new(protocol, created, {
					Now = dependencies.Now,
					IsReady = isReady,
					SendUnreliable = sendUnreliable,
				})

				hints = hintRuntime
				HintState.Install(hintRuntime)
			end

			if hasS2C then
				assert(connectUnreliable ~= nil and isReady ~= nil, "HintUnreliableEndpointMissing")

				local receiver = HintReceiver.new(protocol, created, {
					Now = dependencies.Now,
					IsReady = isReady,
					Notify = HintState.Notify,
				})

				hintReceiver = receiver :: Types.HintReceiverRuntime

				stopUnreliable = connectUnreliable(function(payload: any, ...: any): ()
					receiver:Handle(payload, ...)
				end)
			end

			if hasC2S or hasS2C then
				removedHintActor = ViewRegistry.OnActorViewRemoving:Connect(function(actor): ()
					if hints ~= nil then
						hints:ForgetActor(actor)
					end

					if hintReceiver ~= nil then
						hintReceiver:ForgetActor(actor)
					end
				end)

				local observe = dependencies.ObserveStep

				if observe ~= nil then
					stopHints = observe(function(): ()
						if hints ~= nil then
							hints:Step()
						end

						if hintReceiver ~= nil then
							hintReceiver:Step()
						end
					end)
				end
			end

			local receive: (any) -> (), stop: () -> () = ReliableConsumer.new(
				function(payload: any): ()
					created:Handle(payload)
				end,
				commandRuntime,
				function(): ()
					if onTerminalFailure ~= nil then
						onTerminalFailure()
					end

					cleanup()
				end
			)

			stopReceiver = stop
			installActorReceiver(receive)
		end)

		if not success then
			cleanup()
			error(reason, 0)
		end

		return true, nil, cleanup
	end,
}

return dependencies :: ClientTypes.Dependencies
