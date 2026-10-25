--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local Server = require(KRF.server)
local Actors: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Hints: Types.HintRuntime = require(KRF.server.Networking.HintRuntime)
local Transport = require(KRF.shared.Networking.Transport)
local Scheduling = require(KRF.server.Networking.utils.AwarenessScheduling)
local Authorization = require(KRF.server.Networking.HintAuthorization)
local Schema = require(KRF.shared.Networking.Schema)
local Wire = require(KRF.shared.Networking.HintCodec)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local originalCreate = Transport.Create
local originalPublish = Networking.Publish
local originalStep = Scheduling.ObserveStep
local reliable: BindableEvent
local unreliable: BindableEvent
local barrier: BindableEvent
local player: Player
local protocol: SharedTypes.PreparedProtocol?
local tick: (() -> ())?
local received: { { context: Types.HintContext, payload: any } }
local outbound: { { player: Player, payload: buffer } }
local instances: { Instance } = {}

beforeEach(function()
	Server._ResetForTests()

	reliable, unreliable, barrier =
		Instance.new("BindableEvent"), Instance.new("BindableEvent"), Instance.new("BindableEvent")

	player = ProtocolUtils.createPlayer()
	player.Parent = Players
	instances = { reliable, unreliable, barrier, player }
	protocol, tick, received = nil, nil, {}
	outbound = {}

	Transport.Create = function(): (SharedTypes.OwnedTransport?, string?)
		local root = Instance.new("Folder")
		table.insert(instances, root)

		return {
			root = root,
			reliable = { OnServerEvent = reliable.Event, FireClient = function() end } :: any,
			unreliable = {
				OnServerEvent = unreliable.Event,
				FireClient = function(_self: UnreliableRemoteEvent, recipient: Player, payload: buffer): ()
					table.insert(outbound, { player = recipient, payload = payload })
				end,
			} :: any,
			Destroy = function(): ()
				root:Destroy()
			end,
		},
			nil
	end

	Networking.Publish = function(prepared: SharedTypes.PreparedProtocol): (boolean, string?)
		protocol = prepared

		return originalPublish(prepared)
	end

	Scheduling.ObserveStep = function(callback: () -> ()): () -> ()
		tick = callback

		return function(): ()
			tick = nil
		end
	end

	local started, reason = Server.Init({
		hints = {
			{ id = "A.Server", direction = "ServerToClient", target = "None", mode = "Pulse", payload = Schema.U8 },
			{
				id = "B.Sample",
				direction = "ClientToServer",
				target = "None",
				mode = "Latest",
				payload = Schema.U8,
				authorize = Authorization.AnyReadyClient,
				receive = function(context: Types.HintContext, payload: any): ()
					table.insert(received, { context = context, payload = payload })
				end,
			},
		},
	})

	expect(started).toBe(true)
	expect(reason).toBeNil()
end)

afterEach(function()
	Server._ResetForTests()
	Transport.Create = originalCreate
	Networking.Publish = originalPublish
	Scheduling.ObserveStep = originalStep

	for _, instance in instances do
		instance:Destroy()
	end
end)

local function emit(event: BindableEvent, payload: buffer, extra: boolean?): ()
	if extra ~= nil then
		event:Fire(player, payload, extra)
	else
		event:Fire(player, payload)
	end

	task.defer(function(): ()
		barrier:Fire()
	end)

	barrier.Event:Wait()
end

local function ready(): ()
	emit(reliable, ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	emit(reliable, ProtocolUtils.encode({ kind = "Ready" }))
	expect(Networking.IsClientReady(player)).toBe(true)
end

local function sample(sequence: number): buffer
	local prepared = assert(protocol, "Expected published protocol")
	local codec = Wire.Compile(prepared.runtime)
	local record = assert(codec.EncodeRecord({ hintCode = 1, sequence = sequence, payload = 7 }))
	local packet = assert(codec.Pack({ record }))

	return packet
end

it("installs frozen explicit-recipient sends and revokes the facade on teardown", function()
	local accepted, reason = Hints.SendTo(player, "A.Server", nil, 7)
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	ready()
	expect(table.isfrozen(Hints)).toBe(true)
	accepted, reason = Hints.SendTo(player, "B.Sample", nil, 7)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintDirectionMismatch")
	expect((Hints.SendTo(player, "A.Server", nil, 7))).toBe(true)
	expect(outbound).toEqual({})
	local step = assert(tick, "Expected production Hint scheduler")
	step()
	expect(#outbound).toBe(1)
	expect(outbound[1].player).toBe(player)
	local prepared = assert(protocol, "Expected published codebooks")
	local codec = Wire.Compile(prepared.runtime, "ServerToClient")
	local cursor = assert(codec.Open(outbound[1].payload))
	expect((codec.Read(cursor))).toEqual({ hintCode = 0, payload = 7 })
	player.Parent = nil
	Hints.SendTo(player, "A.Server", nil, 8)
	step()
	expect(#outbound).toBe(1)
	Server._ResetForTests()
	accepted, reason = Hints.SendTo(player, "A.Server", nil, 9)
	expect(accepted).toBe(false)
	expect(reason).toBe("NetworkingNotInitialized")
end)

it("installs the existing unreliable lane and defers validated delivery to the reliable scheduler's tail", function()
	local step = assert(tick, "Expected production scheduler")
	step()
	emit(unreliable, sample(1))
	step()
	expect(received).toEqual({})
	ready()
	emit(unreliable, sample(1))
	expect(received).toEqual({})
	step()
	expect(received).toEqual({ { context = { player = player, hintId = "B.Sample" }, payload = 7 } })
	emit(unreliable, sample(2), true)
	step()
	expect(#received).toBe(1)
	emit(unreliable, sample(1))
	step()
	expect(#received).toBe(1)
	player.Parent = nil
	emit(unreliable, sample(3))
	step()
	expect(#received).toBe(1)
end)

it(
	"preserves unrelated None-target sequence state when an Actor retires and disconnects the listener on teardown",
	function()
		ready()
		local step = assert(tick, "Expected production scheduler")
		emit(unreliable, sample(1))
		step()

		local model = Instance.new("Model")
		model.Parent = workspace
		table.insert(instances, model)
		local actor = assert(Actors.RegisterActor(model))
		Actors.UnregisterActor(actor)
		emit(unreliable, sample(1))
		step()
		expect(#received).toBe(1)
		step()
		Server._ResetForTests()
		emit(unreliable, sample(2))
		step()
		expect(#received).toBe(1)
		expect(tick).toBeNil()
	end
)
