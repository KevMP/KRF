--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientTypes = require(script.Parent.Parent.types)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local Transport = require(script.Parent.Parent.Parent.shared.Networking.Transport)
local SchemaTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)
local StreamTypes = require(script.Parent.ActorStreamTypes)
local Stream = require(script.Parent.ActorStreamRuntime)
local Discovery = require(script.Parent.ActorModelDiscovery)
local Consumer = require(script.Parent.ActorStreamConsumer)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamCodec)
local SchemaCompiler = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.ActorProtocolConstants)

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
	InstallConsumers = function(
		protocol: ProtocolTypes.ClientProtocol,
		manifest: ProtocolTypes.ProtocolManifest?,
		installActorReceiver: (((any) -> ()) -> ())?
	): (boolean, string?, (() -> ())?)
		assert(manifest ~= nil and installActorReceiver ~= nil, "ActorInstallationMissing")
		local schemas: WireTypes.SchemaCatalog = {}
		for _, domain: ProtocolTypes.ManifestDomain in manifest.domains do
			local schema: SchemaTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(domain.state)
			assert(schema ~= nil, reason)
			schemas[domain.id] = schema
		end
		local codec: WireTypes.Codec = Codec.Compile(protocol, schemas)
		local discovery: StreamTypes.DiscoveryAdapter = Discovery.new()
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
		local runtime: StreamTypes.Runtime = result
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
