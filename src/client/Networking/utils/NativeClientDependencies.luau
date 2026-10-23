--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientTypes = require(script.Parent.Parent.Parent.types)
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

local dependencies: ClientTypes.Dependencies

dependencies = {
	Now = os.clock,
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
		isReady: (() -> boolean)?
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

		local function cleanup(): ()
			if not active then
				return
			end

			active = false

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

			local receive: (any) -> (), stop: () -> () = ReliableConsumer.new(function(payload: any): ()
				created:Handle(payload)
			end, commandRuntime, cleanup)

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

return dependencies
