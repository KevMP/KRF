--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ServerTypes = require(KRF.server.types)
local Marker: ServerNetworkingTypes.ActorModelMarkerModule = require(KRF.server.Networking.utils.ActorModelMarker)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Registry: ActorTypes.ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Handshake: ServerNetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Server = require(KRF.server)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local fixture: TestUtils.Fixture
local handshake: ServerNetworkingTypes.ServerHandshake? = nil
local models: { Model } = {}
local originalInstall: typeof(Marker.Install) = Marker.Install
beforeEach(function()
	Server._ResetForTests()
	fixture = TestUtils.new()
end)
afterEach(function()
	Marker.Install = originalInstall
	TestUtils.destroy(fixture)
	if handshake ~= nil then
		handshake:Destroy()
		handshake = nil
	end
	Server._ResetForTests()
	for _, model: Model in models do
		model:Destroy()
	end
	models = {}
end)

it("orders real N2 READY_ACK before baseline work initiated by the private Ready lifecycle", function()
	local player: Player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	local order: { string } = {}
	handshake = Handshake.new(fixture.protocol, {
		SendReliable = function(_recipient: Player, payload: buffer): ()
			table.insert(order, ProtocolUtils.decode(payload).kind)
		end,
	})
	local installed: ServerNetworkingTypes.ServerHandshake = handshake
	fixture.dependencies.IsClientReady = function(recipient: Player): boolean
		return installed:IsClientReady(recipient)
	end
	fixture.dependencies.ObserveClientReady = function(callback: (Player) -> ()): () -> ()
		return installed:ObserveClientReady(callback)
	end
	fixture.dependencies.ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
		return installed:ObserveClientClosed(callback)
	end
	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		table.insert(order, "ActorPacket")
		table.insert(fixture.deliveries, { player = recipient, payload = payload })
		return true, nil
	end
	TestUtils.start(fixture)
	installed:Handle(player, ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	TestUtils.drain(fixture)
	expect(order).toEqual({ "Bootstrap" })
	installed:Handle(player, ProtocolUtils.encode({ kind = "Ready" }))
	TestUtils.drain(fixture)
	expect(order[2]).toBe("ReadyAck")
	expect(order[3]).toBe("ActorPacket")
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	fixture.deliveries = {}
	installed:Close(player)
	TestUtils.drain(fixture)
	expect(fixture.deliveries).toEqual({})
end)

it("installs identity synchronously before RegisterActor returns and removes it on explicit teardown", function()
	local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	local marker: Instance? = Marker.GetMarker(model)
	assert(marker ~= nil, "Successful registration must already have N4 identity")
	expect(Marker.GetActorId(marker)).toBe(actor:GetId())
	expect(ActorRuntime.UnregisterActor(actor)).toBe(true)
	expect(Marker.GetMarker(model)).toBeNil()
	expect(Registry.GetActorByModel(model)).toBeNil()
end)

it("rolls back N3, controllers and Model binding when marker installation fails before live registration", function()
	expect(Server.Init({})).toBe(true)
	local publication: ServerNetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Expected startup-owned N3")
	local attempted: ActorTypes.Actor? = nil
	Marker.Install = function(actor: ActorTypes.Actor): (boolean, string?)
		attempted = actor
		expect(actor.enabled).toBe(false)
		expect(publication:CaptureBaseline(actor)).never.toBeNil()
		return false, "ForcedMarkerFailure"
	end
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(actor).toBeNil()
	expect(reason).toBe("ForcedMarkerFailure")
	assert(attempted ~= nil, "Expected marker installation attempt")
	expect(attempted.enabled).toBe(false)
	expect(attempted:GetControllerKeys()).toEqual({})
	expect(attempted.model).toBeNil()
	expect(Registry.GetActorByModel(model)).toBeNil()
	expect(publication:GetAttachedActors()).toEqual({})
	expect(model:GetChildren()).toEqual({})
end)
