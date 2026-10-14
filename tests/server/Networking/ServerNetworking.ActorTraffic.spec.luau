--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local AwarenessTypes = require(KRF.server.Networking.AwarenessTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local ReplicationTypes = require(KRF.server.Replication.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Transport: ProtocolTypes.Transport = require(KRF.shared.Networking.Transport)
local Handshake: NetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Scheduling: AwarenessTypes.SchedulingModule = require(KRF.server.Networking.AwarenessScheduling)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Server = require(KRF.server)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)
local Constants = require(KRF.shared.Networking.ProtocolConstants)

local originalCreate: typeof(Transport.Create) = Transport.Create
local originalHandshake: typeof(Handshake.new) = Handshake.new
local originalStep: typeof(Scheduling.ObserveStep) = Scheduling.ObserveStep
local connection: NetworkingTypes.ServerHandshake?
local protocol: ProtocolTypes.PreparedProtocol?
local step: (() -> ())?
local instances: { Instance } = {}
local sent: { buffer } = {}
beforeEach(function()
	Server._ResetForTests()
	connection = nil
	protocol = nil
	step = nil
	sent = {}
	Transport.Create = function(_parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
		local root: Folder = Instance.new("Folder")
		local incoming: BindableEvent = Instance.new("BindableEvent")
		table.insert(instances, root)
		table.insert(instances, incoming)
		return {
			root = root,
			unreliable = {} :: any,
			reliable = {
				OnServerEvent = incoming.Event,
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
	Handshake.new = function(
		prepared: ProtocolTypes.PreparedProtocol,
		dependencies: NetworkingTypes.HandshakeDependencies
	): NetworkingTypes.ServerHandshake
		protocol = prepared
		local created: NetworkingTypes.ServerHandshake = originalHandshake(prepared, dependencies)
		connection = created
		return created
	end
	Scheduling.ObserveStep = function(callback: () -> ()): () -> ()
		step = callback
		return function()
			step = nil
		end
	end
end)
afterEach(function()
	Server._ResetForTests()
	Transport.Create = originalCreate
	Handshake.new = originalHandshake
	Scheduling.ObserveStep = originalStep
	for _, instance: Instance in instances do
		instance:Destroy()
	end
	instances = {}
end)

for _, oversized: boolean in { false, true } do
	it("runs production handshake, awareness and Reliable delivery with oversized=" .. tostring(oversized), function()
		local current: string = if oversized then string.rep("x", 300000) else "first"
		local snapshots: number = 0
		local committed: ReplicationTypes.ReplicationDomainOnCommitted? = nil
		local state: SchemaTypes.SchemaDefinition = Schema.String(300000)
		expect(Server.Init({
			replicationDomains = {
				{
					id = "Game.Large",
					state = state,
					snapshot = function(_actor: ActorTypes.Actor): any
						snapshots += 1
						return current
					end,
					observe = function(
						_actor: ActorTypes.Actor,
						callback: ReplicationTypes.ReplicationDomainOnCommitted
					): (() -> ())?
						committed = callback
						return nil
					end,
				},
			},
		})).toBe(true)
		local model: Model = Instance.new("Model")
		model.Parent = workspace
		table.insert(instances, model)
		local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
		assert(actor ~= nil, reason)
		local player: Player = ProtocolUtils.createPlayer()
		table.insert(instances, player)
		assert(connection ~= nil and protocol ~= nil and step ~= nil, "Expected production lifecycle")
		connection:Handle(player, ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
		connection:Handle(player, ProtocolUtils.encode({ kind = "Ready" }))
		expect(ProtocolUtils.decode(sent[1]).kind).toBe("Bootstrap")
		expect(ProtocolUtils.decode(sent[2]).kind).toBe("ReadyAck")
		for _ = 1, 8 do
			step()
		end
		if oversized then
			expect(#sent).toBe(2)
		else
			local codec: WireTypes.Codec =
				Codec.Compile(protocol.runtime, { ["Game.Large"] = SchemaUtils.compile(state) })
			local records: { WireTypes.Record } = {}
			for index: number = 3, #sent do
				local decoded: { WireTypes.Record }?, decodeReason: string? = codec.Decode(sent[index])
				assert(decoded ~= nil, decodeReason)
				for _, record: WireTypes.Record in decoded do
					table.insert(records, record)
				end
			end
			expect(records[1].kind).toBe("BaselineBegin")
			expect(records[#records].kind).toBe("BaselineEnd")
			local previous: number = #sent
			current = "second"
			assert(committed ~= nil, "Expected domain observer")
			committed()
			for _ = 1, 8 do
				step()
			end
			expect(#sent).toBe(previous + 1)
			local live: { WireTypes.Record }?, liveReason: string? = codec.Decode(sent[#sent])
			assert(live ~= nil, liveReason)
			expect(live[1].kind).toBe("Commit")
		end
		expect(snapshots).toBe(if oversized then 1 else 2)
		Networking.Destroy()
		expect(ActorRuntime.UnregisterActor(actor)).toBe(true)
		expect(model:GetChildren()).toEqual({})
	end)
end
