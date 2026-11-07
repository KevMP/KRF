--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local ClientTypes = require(KRF.client.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ClientTestUtils)
local fixture: Utils.Fixture
local actor: ActorTypes.ActorViewOwner

beforeEach(function()
	Client._ResetForTests()
	Registry.Reset()
	fixture = Utils.new()
	actor = assert(Actor.new("ActorA", nil, {}))
	assert(Registry.Install(actor.view))
end)

afterEach(function()
	Client._ResetForTests()

	if fixture.initThread ~= nil and coroutine.status(fixture.initThread) ~= "dead" then
		coroutine.close(fixture.initThread)
	end

	actor:Destroy()
	Registry.Reset()
end)

it("keeps the frozen facade stable and returns ClientNotReady while uninstalled", function()
	expect(table.isfrozen(Runtime)).toBe(true)
	expect(State.Get()).toBeNil()
	expect({ Runtime.SetProfileSource(actor.view, "Base", { routes = {} }) }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.RemoveProfileSource(actor.view, "Base") }).toEqual({ false, "ClientNotReady" })
	expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ false, "ClientNotReady" })
	expect(Runtime.GetControlledActor()).toBeNil()
	expect(Runtime.GetEffectiveRoute(actor.view, { kind = "Input", inputId = "X", gesture = "Pressed" })).toBeNil()
	expect(Runtime.GetProfileSources(actor.view)).toEqual({})
	expect((Runtime :: any).Install).toBeNil()
	expect((Runtime :: any).Sink).toBeNil()
end)

it("installs the action owner after input and Actor registry readiness before successful Init returns", function()
	Utils.start(fixture)
	expect(State.Get()).toBeNil()
	Utils.bootstrap(fixture)
	expect(InputState.Get()).never.toBeNil()
	expect(State.Get()).never.toBeNil()
	expect({ Runtime.SetProfileSource(actor.view, "Base", { routes = {} }) }).toEqual({ false, "ClientNotReady" })
	Utils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect({ Runtime.SetProfileSource(actor.view, "Base", { routes = {} }) }).toEqual({ true })
	expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ true })
	expect(Runtime.GetControlledActor()).toBe(actor.view)
	expect(#fixture.sent).toBe(2)
end)

it("uninstalls the original owner on failed startup and does not revive it after reset", function()
	Utils.start(fixture)
	Utils.bootstrap(fixture)
	local original: Types.ClientActionOwner = assert(State.Get(), "Expected action owner before ReadyAck")
	assert(fixture.timeoutCallback, "Expected startup deadline")()
	expect(State.Get()).toBeNil()
	expect(original.GetControlledActor()).toBeNil()
	expect({ original.SetControlledActor(actor.view) }).toEqual({ false, "ClientNotReady" })
	Client._ResetForTests()
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

it("cleans the route owner on terminal consumer failure before removing input and Actor consumers", function()
	local terminate: (() -> ())? = nil
	local install = fixture.dependencies.InstallConsumers

	fixture.dependencies.InstallConsumers = function(
		protocol: NetworkingTypes.ClientProtocol,
		manifest: NetworkingTypes.ProtocolManifest?,
		receiver: (((any) -> ()) -> ())?,
		send: ((buffer) -> ())?,
		ready: (() -> boolean)?,
		terminal: (() -> ())?
	): (boolean, string?, (() -> ())?)
		terminate = terminal

		return install(protocol, manifest, receiver, send, ready, terminal)
	end

	Utils.start(fixture)
	Utils.bootstrap(fixture)
	Utils.acknowledge(fixture)
	local original: Types.ClientActionOwner = assert(State.Get(), "Expected installed action owner")
	expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ true })
	assert(terminate, "Expected terminal failure callback")()
	expect(State.Get()).toBeNil()
	expect(InputState.Get()).toBeNil()
	expect(Runtime.GetControlledActor()).toBeNil()
	expect(original.GetProfileSources(actor.view)).toEqual({})
	expect({ original.SetControlledActor(actor.view) }).toEqual({ false, "ClientNotReady" })
	Client._ResetForTests()
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

it("retains facade identity across owner lifetimes and makes old owner callbacks inert", function()
	Utils.start(fixture)
	Utils.bootstrap(fixture)
	Utils.acknowledge(fixture)
	local original: Types.ClientActionOwner = assert(State.Get(), "Expected initial action owner")
	Client._ResetForTests()
	Client._ResetForTests()
	expect(State.Get()).toBeNil()
	fixture = Utils.new()
	Utils.start(fixture)
	Utils.bootstrap(fixture)
	Utils.acknowledge(fixture)
	expect(State.Get()).never.toBe(original)
	expect(table.isfrozen(Runtime)).toBe(true)
	expect({ original.RemoveProfileSource(actor.view, "Base") }).toEqual({ false, "ClientNotReady" })
	expect(Runtime.GetControlledActor()).toBeNil()
end)
