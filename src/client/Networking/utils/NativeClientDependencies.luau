--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientTypes = require(script.Parent.Parent.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Transport = require(script.Parent.Parent.Parent.Parent.shared.Networking.Transport)
local Types = require(script.Parent.Parent.types)
local Stream = require(script.Parent.Parent.ActorStreamRuntime)
local Discovery = require(script.Parent.ActorModelDiscovery)
local Consumer = require(script.Parent.ActorStreamConsumer)
local Codec = require(script.Parent.Parent.Parent.Parent.shared.Networking.ActorStreamCodec)
local SchemaCompiler = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

local dependencies: ClientTypes.Dependencies = {
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
		installActorReceiver: (((any) -> ()) -> ())?
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
		local success: boolean, result: any = pcall(Stream.new, codec, Consumer.Get(), discovery, {
			maxBaselineBytes = Constants.MAX_BASELINE_BYTES,
			maxPendingBaselines = Constants.MAX_PENDING_BASELINES,
			ReportFault = function(reason: string)
				warn("[Networking] Actor stream fault: " .. reason)
			end,
		})
		if not success then
			discovery.Destroy()
			error(result, 0)
		end
		local runtime: Types.ActorStreamRuntime = result
		local active: boolean = true
		installActorReceiver(function(payload: any)
			if active then
				runtime:Handle(payload)
			end
		end)
		return true,
			nil,
			function()
				if not active then
					return
				end
				active = false
				runtime:Destroy()
				discovery.Destroy()
			end
	end,
}

return dependencies
