--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local ClientTypes = require(KRF.client.types)
local NetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local Runtime: Types.InputRuntime = require(KRF.client.Input.InputRuntime)
local State = require(KRF.client.Input.utils.InputRuntimeState)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local InputTestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	Client._ResetForTests()
	fixture = TestUtils.new()
end)

afterEach(function()
	Client._ResetForTests()

	if fixture.initThread ~= nil and coroutine.status(fixture.initThread) ~= "dead" then
		coroutine.close(fixture.initThread)
	end
end)

it("installs the real input owner before successful Init returns and gates mutations before ReadyAck", function()
	TestUtils.start(fixture)
	expect(State.Get()).toBeNil()
	TestUtils.bootstrap(fixture)
	expect(State.Get()).never.toBeNil()
	expect({ Runtime.SetSource("Core", InputTestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(State.Get()).never.toBeNil()
	expect(Runtime.SetSource("Empty", {})).toBe(true)
end)

it("uninstalls input on failed startup and disconnects event listeners exactly once", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	local event = Runtime.OnInput
	local oldCalls: number = 0

	event:Connect(function()
		oldCalls += 1
	end)

	assert(fixture.timeoutCallback ~= nil, "Expected initialized input state")
	fixture.timeoutCallback()
	expect(State.Get()).toBeNil()

	State.Notify({
		kind = "Pressed",
		inputId = "Primary",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
		value = true,
		timestamp = 1,
		ordinal = 1,
	})

	expect(oldCalls).toBe(0)
	expect(Runtime.OnInput).toBe(event)
	expect({ Runtime.RemoveSource("Core") }).toEqual({ false, "ClientNotReady" })
	Client._ResetForTests()
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

it("cleans input on reset and never reconnects a prior event subscription", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	local original: Types.InputOwner = assert(State.Get(), "Expected initialized input state")
	local event = Runtime.OnInput
	local oldCalls: number = 0

	event:Connect(function()
		oldCalls += 1
	end)

	Client._ResetForTests()
	Client._ResetForTests()
	expect(State.Get()).toBeNil()
	expect({ original.SetSource("Core", InputTestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	fixture = TestUtils.new()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	expect(State.Get()).never.toBe(original)
	expect(Runtime.OnInput).toBe(event)

	State.Notify({
		kind = "Pressed",
		inputId = "Primary",
		contextId = "Gameplay",
		inputType = Enum.InputActionType.Bool,
		value = true,
		timestamp = 1,
		ordinal = 1,
	})

	expect(oldCalls).toBe(0)
end)

it("uninstalls the input owner on a terminal client consumer failure", function()
	local terminate: (() -> ())? = nil
	local install = fixture.dependencies.InstallConsumers

	fixture.dependencies.InstallConsumers = function(
		protocol: NetworkingTypes.ClientProtocol,
		manifest: NetworkingTypes.ProtocolManifest?,
		installActorReceiver: (((any) -> ()) -> ())?,
		sendReliable: ((buffer) -> ())?,
		isReady: (() -> boolean)?,
		onTerminalFailure: (() -> ())?
	): (boolean, string?, (() -> ())?)
		terminate = onTerminalFailure

		return install(protocol, manifest, installActorReceiver, sendReliable, isReady, onTerminalFailure)
	end

	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	local owner: Types.InputOwner = assert(State.Get(), "Expected initialized input state")
	assert(terminate ~= nil, "Expected initialized input state")
	terminate()
	expect(State.Get()).toBeNil()
	expect({ owner.SetSource("Core", InputTestUtils.definition()) }).toEqual({ false, "ClientNotReady" })
	expect(fixture.consumerCleanupCalls).toBe(1)
	Client._ResetForTests()
	expect(fixture.consumerCleanupCalls).toBe(1)
end)
