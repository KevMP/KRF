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
local NetworkingTypes = require(KRF.server.Networking.types)
local AwarenessTypes = require(KRF.server.Networking.AwarenessTypes)
local ResyncTypes = require(KRF.server.Networking.ResyncTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Transport: ProtocolTypes.Transport = require(KRF.shared.Networking.Transport)
local Scheduling: AwarenessTypes.SchedulingModule = require(KRF.server.Networking.AwarenessScheduling)
local Control: ResyncTypes.RuntimeModule = require(KRF.server.Networking.ResyncRuntime)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Server = require(KRF.server)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local ResyncCodec = require(KRF.shared.Networking.ResyncCodec)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)

local originalCreate: typeof(Transport.Create) = Transport.Create
local originalStep: typeof(Scheduling.ObserveStep) = Scheduling.ObserveStep
local originalControl: typeof(Control.new) = Control.new
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
local codec: WireTypes.Codec

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
	Transport.Create = function(_parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
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
	Control.new = function(dependencies: ResyncTypes.Dependencies, options: ResyncTypes.Options): ResyncTypes.Runtime
		controls += 1
		local runtime: ResyncTypes.Runtime = originalControl(dependencies, options)
		local handle: typeof(runtime.Handle) = runtime.Handle
		local destroy: typeof(runtime.Destroy) = runtime.Destroy
		runtime.Handle = function(
			self: ResyncTypes.Runtime,
			recipient: Player,
			payload: any,
			...: any
		): (boolean, string?)
			handled += 1
			return handle(self, recipient, payload, ...)
		end
		runtime.Destroy = function(self: ResyncTypes.Runtime)
			destroyed += 1
			destroy(self)
		end
		return runtime
	end
	local success: boolean, failure: any = Server.Init({
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
	local manifest: ProtocolTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = { { id = "Game.Recovery", code = 0, state = Schema.U8, events = {} } },
	}
	local protocol: ProtocolTypes.ClientProtocol?
	protocol, reason = Manifest.Reconstruct(manifest)
	assert(protocol ~= nil, reason)
	codec = Codec.Compile(protocol, { ["Game.Recovery"] = SchemaUtils.compile(Schema.U8) })
end)
afterEach(function()
	Server._ResetForTests()
	Transport.Create = originalCreate
	Scheduling.ObserveStep = originalStep
	Control.new = originalControl
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
		local records: { WireTypes.Record }?, reason: string? = codec.Decode(sent[index])
		assert(records ~= nil, reason)
		for _, record: WireTypes.Record in records do
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
			local records: { WireTypes.Record }?, reason: string? = codec.Decode(payload)
			assert(records ~= nil, reason)
			for _, record: WireTypes.Record in records do
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
