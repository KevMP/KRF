--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Transport: SharedNetworkingTypes.Transport = require(KRF.shared.Networking.Transport)

local Scheduling: ServerNetworkingTypes.AwarenessSchedulingModule =
	require(KRF.server.Networking.utils.AwarenessScheduling)

local Control: ServerNetworkingTypes.ResyncRuntimeModule = require(KRF.server.Networking.ResyncRuntime)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Server = require(KRF.server)
local Codec: SharedNetworkingTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)
local Commands: ServerNetworkingTypes.ServerCommandRuntimeModule = require(KRF.server.Networking.ServerCommandRuntime)

local Awareness: ServerNetworkingTypes.ActorAwarenessRuntimeModule =
	require(KRF.server.Networking.ActorAwarenessRuntime)

local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local CommandConstants = require(KRF.shared.Networking.utils.CommandConstants)
local Authorization = require(KRF.server.Networking.CommandAuthorization)

local originalCreate: typeof(Transport.Create) = Transport.Create
local originalStep: typeof(Scheduling.ObserveStep) = Scheduling.ObserveStep
local originalControl: typeof(Control.new) = Control.new
local originalCommands: typeof(Commands.new) = Commands.new
local originalAwareness: typeof(Awareness.new) = Awareness.new
local commandDependencies: ServerNetworkingTypes.ServerCommandDependencies? = nil
local awarenessDependencies: ServerNetworkingTypes.ActorAwarenessDependencies? = nil
local commandCodec: SharedNetworkingTypes.CommandCodec
local commandCalls: number = 0
local inbound: BindableEvent
local barrier: BindableEvent
local root: Folder
local player: Player
local model: Model
local step: (() -> ())?
local sent: { buffer }
local controls: number
local destroyed: number
local handled: number
local codec: SharedNetworkingTypes.ActorStreamCodec

beforeEach(function()
	Server._ResetForTests()
	inbound = Instance.new("BindableEvent")
	barrier = Instance.new("BindableEvent")
	root = Instance.new("Folder")
	player = ProtocolUtils.createPlayer()
	player.Parent = Players
	model = Instance.new("Model")
	sent = {}
	controls = 0
	destroyed = 0
	handled = 0
	step = nil
	commandCalls = 0
	commandDependencies = nil
	awarenessDependencies = nil

	Commands.new = function(
		catalog: ServerNetworkingTypes.PreparedCommandCatalog,
		protocol: SharedNetworkingTypes.ClientProtocol,
		dependencies: ServerNetworkingTypes.ServerCommandDependencies,
		options: ServerNetworkingTypes.ServerCommandLimits?
	): ServerNetworkingTypes.ServerCommandRuntime
		commandDependencies = dependencies
		commandCodec = CommandCodec.Compile(protocol)

		return originalCommands(catalog, protocol, dependencies, options)
	end

	Awareness.new = function(
		publication: ServerNetworkingTypes.PublicationRuntime,
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		protocol: SharedNetworkingTypes.ClientProtocol,
		dependencies: ServerNetworkingTypes.ActorAwarenessDependencies,
		options: ServerNetworkingTypes.ActorAwarenessOptions
	): ServerNetworkingTypes.ActorAwarenessRuntime
		awarenessDependencies = dependencies

		return originalAwareness(publication, catalog, protocol, dependencies, options)
	end

	Transport.Create = function(_parent: Instance): (SharedNetworkingTypes.OwnedTransport?, string?)
		return {
			root = root,
			unreliable = {} :: any,
			reliable = {
				OnServerEvent = inbound.Event,
				FireClient = function(_self: any, _recipient: Player, payload: buffer)
					table.insert(sent, payload)
				end,
			} :: any,
			Destroy = function()
				root:Destroy()
			end,
		},
			nil
	end

	Scheduling.ObserveStep = function(callback: () -> ()): () -> ()
		step = callback

		return function()
			step = nil
		end
	end

	Control.new = function(
		dependencies: ServerNetworkingTypes.ResyncDependencies,
		options: ServerNetworkingTypes.ResyncOptions
	): ServerNetworkingTypes.ResyncRuntime
		controls += 1
		local runtime: ServerNetworkingTypes.ResyncRuntime = originalControl(dependencies, options)
		local handle: typeof(runtime.Handle) = runtime.Handle
		local destroy: typeof(runtime.Destroy) = runtime.Destroy

		runtime.Handle = function(
			self: ServerNetworkingTypes.ResyncRuntime,
			recipient: Player,
			payload: any,
			...: any
		): (boolean, string?)
			handled += 1

			return handle(self, recipient, payload, ...)
		end

		runtime.Destroy = function(self: ServerNetworkingTypes.ResyncRuntime)
			destroyed += 1
			destroy(self)
		end

		return runtime
	end

	local success: boolean, failure: any = Server.Init({
		commands = {
			{
				id = "Game.Probe",
				target = "None",
				result = Schema.U8,
				authorize = Authorization.AnyReadyClient,
				handle = function(): ServerNetworkingTypes.CommandHandlerResult
					commandCalls += 1

					return { accepted = true, result = 7 }
				end,
			},
			{
				id = "Game.Fault",
				target = "None",
				authorize = Authorization.AnyReadyClient,
				handle = function(): ServerNetworkingTypes.CommandHandlerResult
					error("InjectedCommandFault")
				end,
			},
		},
		replicationDomains = {
			{
				id = "Game.Recovery",
				state = Schema.U8,
				snapshot = function(_actor: ActorTypes.Actor): any
					return 10
				end,
			},
		},
	})

	expect(success).toBe(true)
	expect(failure).toBeNil()
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	assert(actor ~= nil, reason)

	local manifest: SharedNetworkingTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = { { id = "Game.Recovery", code = 0, state = Schema.U8, events = {} } },
	}

	local protocol: SharedNetworkingTypes.ClientProtocol?
	protocol, reason = Manifest.Reconstruct(manifest)
	assert(protocol ~= nil, reason)
	codec = Codec.Compile(protocol, { ["Game.Recovery"] = SchemaUtils.compile(Schema.U8) })
end)

afterEach(function()
	Server._ResetForTests()
	Transport.Create = originalCreate
	Scheduling.ObserveStep = originalStep
	Control.new = originalControl
	Commands.new = originalCommands
	Awareness.new = originalAwareness
	inbound:Destroy()
	barrier:Destroy()
	root:Destroy()
	player:Destroy()
	model:Destroy()
end)

local function emit(payload: buffer, ...: any): ()
	inbound:Fire(player, payload, ...)

	task.defer(function()
		barrier:Fire()
	end)

	barrier.Event:Wait()
end

local function ready(): number
	emit(ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	emit(ProtocolUtils.encode({ kind = "Ready" }))
	expect(Networking.IsClientReady(player)).toBe(true)
	assert(step ~= nil, "Expected production awareness driver")

	for _ = 1, 8 do
		step()
	end

	local handle: number? = nil

	for index: number = 3, #sent do
		local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(sent[index])
		assert(records ~= nil, reason)

		for _, record: SharedNetworkingTypes.ActorStreamRecord in records do
			if record.kind == "BaselineBegin" then
				handle = record.handle
			end
		end
	end

	assert(handle ~= nil, "Expected real production Actor baseline")
	sent = {}

	return handle
end

local function request(handle: number): buffer
	local payload: buffer?, reason: string? = ResyncCodec.Encode(handle)
	assert(payload ~= nil, reason)

	return payload
end

it(
	"installs recovery control with server startup and routes Reliable requests into the real N4 replacement machinery",
	function()
		expect(controls).toBe(1)
		local handle: number = ready()
		emit(request(handle))
		expect(handled).toBe(1)
		assert(step ~= nil, "Expected active driver")

		for _ = 1, 8 do
			step()
		end

		local began: number = 0
		local ended: number = 0

		for _, payload: buffer in sent do
			local records: { SharedNetworkingTypes.ActorStreamRecord }?, reason: string? = codec.Decode(payload)
			assert(records ~= nil, reason)

			for _, record: SharedNetworkingTypes.ActorStreamRecord in records do
				if record.kind == "BaselineBegin" then
					began += 1
					expect(record.actorId).toBeNil()
					expect(record.generation).toBe(2)
				elseif record.kind == "BaselineEnd" then
					ended += 1
				end
			end
		end

		expect(began).toBe(1)
		expect(ended).toBe(1)
	end
)

it("keeps non-Ready recovery traffic from establishing awareness or completing a handshake", function()
	expect(controls).toBe(1)
	emit(request(1))
	expect(Networking.IsClientReady(player)).toBe(false)
	expect(sent).toEqual({})
end)

it("rejects extra control arguments without scheduling a replacement or corrupting a Ready connection", function()
	expect(controls).toBe(1)
	local handle: number = ready()
	emit(request(handle), "unexpected")
	assert(step ~= nil, "Expected active driver")

	for _ = 1, 8 do
		step()
	end

	expect(sent).toEqual({})
	expect(Networking.IsClientReady(player)).toBe(true)
end)

it("destroys the owned recovery handler once and stops dispatch after server teardown", function()
	expect(controls).toBe(1)
	local handle: number = ready()
	Networking.Destroy()
	Networking.Destroy()
	emit(request(handle))
	expect(destroyed).toBe(1)
	expect(handled).toBe(0)
end)

it("dispatches command buffers separately from handshake and resync and queues validated results through N4", function()
	local payload: buffer?, reason: string? = commandCodec.EncodeRequest({ commandCode = 1, requestId = 1 })
	assert(payload ~= nil, reason)
	emit(payload)
	expect(commandCalls).toBe(0)
	local handle: number = ready()
	emit(payload)
	emit(request(handle))
	local faulty: buffer? = commandCodec.EncodeRequest({ commandCode = 0, requestId = 2 })
	assert(faulty ~= nil, "Expected schema-valid faulting request")
	emit(faulty)
	expect(commandCalls).toBe(1)
	expect(handled).toBe(1)
	expect(sent).toEqual({})
	assert(step ~= nil, "Expected production scheduler")

	for _ = 1, 12 do
		step()
	end

	local outcomes: { SharedNetworkingTypes.CommandResult } = {}

	for _, packet: buffer in sent do
		if buffer.readu8(packet, 0) == CommandConstants.RESULT_KIND then
			local outcome: SharedNetworkingTypes.CommandResult? = commandCodec.DecodeResult(packet)
			assert(outcome ~= nil, "Expected production result codec")
			table.insert(outcomes, outcome)
		end
	end

	expect(outcomes).toEqual({
		{ commandCode = 1, requestId = 1, status = "Accepted", result = 7 },
		{ commandCode = 0, requestId = 2, status = "Unknown", reason = "CommandHandlerFault" },
	})

	assert(commandDependencies ~= nil, "Expected startup-owned command dependencies")
	commandDependencies.CloseConnection(player, "OutputUnavailable")
	expect(Networking.IsClientReady(player)).toBe(false)
	emit(payload)
	expect(commandCalls).toBe(1)
end)

it("closes the same handshake connection when N4 reports an unrecoverable command-output failure", function()
	ready()

	assert(
		awarenessDependencies ~= nil and awarenessDependencies.CloseConnection ~= nil,
		"Expected private N4 connection cleanup"
	)

	awarenessDependencies.CloseConnection(player, "CommandOutputExpired")
	expect(Networking.IsClientReady(player)).toBe(false)
	assert(commandDependencies ~= nil, "Expected command runtime cleanup binding")
	expect(commandDependencies.IsClientReady(player)).toBe(false)
end)
