--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
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
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)

local HintInstallation = require(script.Parent.ClientHintInstallation)

local Installation = {}

function Installation.Install(
	protocol: SharedNetworkingTypes.ClientProtocol,
	manifest: SharedNetworkingTypes.ProtocolManifest?,
	options: Types.ClientConsumerInstallationOptions
): (boolean, string?, (() -> ())?)
	assert(manifest ~= nil and options.installActorReceiver ~= nil, "ActorInstallationMissing")
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
	local diagnosticOwner = Diagnostics.Get()
	local commands: Types.ClientCommandRuntime? = nil
	local stopReceiver: (() -> ())? = nil
	local stopHintInstallation: (() -> ())? = nil

	local function cleanup(): ()
		if not active then
			return
		end

		active = false

		if stopHintInstallation ~= nil then
			stopHintInstallation()
			stopHintInstallation = nil
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
			assert(options.sendReliable ~= nil, "ActorReliableEndpointMissing")

			local created: Types.ActorViewRuntime = Views.new(protocol, schemas, {
				Now = options.Now,
				ScheduleTimeout = options.ScheduleTimeout,
				SendReliable = options.sendReliable,
				ReportFault = function(fault: Types.ActorViewFault, terminal: boolean?)
					if terminal then
						-- Terminal ActorView faults already transition once per live owner.
						warn("[Networking] ActorView fault actorId=" .. fault.actorId .. " reason=" .. fault.reason)
					else
						Metrics.Warn(diagnosticOwner, "BaselineRecovery", fault.reason)
					end
				end,
			})

			views = created
			consumer = created.consumer
		end

		local created: Types.ActorStreamRuntime = Stream.new(codec, consumer, discovery, {
			maxBaselineBytes = Constants.MAX_BASELINE_BYTES,
			maxPendingBaselines = Constants.MAX_PENDING_BASELINES,
			ReportFault = function(fault: string)
				Metrics.Warn(diagnosticOwner, "ActorStreamFault", fault)
			end,
		})

		runtime = created
		assert(options.sendReliable ~= nil, "CommandReliableEndpointMissing")

		local commandRuntime: Types.ClientCommandRuntime = Commands.new(protocol, created, {
			IsReady = options.isReady or function(): boolean
				return false
			end,
			SendReliable = options.sendReliable,
			ScheduleTimeout = options.ScheduleTimeout,
		})

		commands = commandRuntime
		CommandState.Install(commandRuntime)
		stopHintInstallation = HintInstallation.Install(protocol, created, options)

		local receive: (any) -> (), stop: () -> () = ReliableConsumer.new(
			function(payload: any): ()
				created:Handle(payload)
			end,
			commandRuntime,
			function(): ()
				if options.onTerminalFailure ~= nil then
					options.onTerminalFailure()
				end

				cleanup()
			end
		)

		stopReceiver = stop
		options.installActorReceiver(receive)
	end)

	if not success then
		cleanup()
		error(reason, 0)
	end

	return true, nil, cleanup
end

return Installation
