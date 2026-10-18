--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Client: ClientTypes.Client = require(KRF.client)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

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

it("installs its listener before emitting a buffer HELLO with the exact protocol version", function()
	TestUtils.start(fixture)
	expect(fixture.order).toEqual({ "Listen", "Hello" })
	expect(ProtocolTestUtils.decode(fixture.sent[1])).toEqual({ kind = "Hello", version = Constants.PROTOCOL_VERSION })
	expect(fixture.result).toBeNil()
	expect(Client._IsInitialized()).toBe(false)
end)

it("remains pending before BOOTSTRAP and after READY until READY_ACK", function()
	TestUtils.start(fixture)
	expect(fixture.result).toBeNil()
	TestUtils.bootstrap(fixture)
	expect(fixture.order).toEqual({ "Listen", "Hello", "Consumers", "Ready" })
	expect(fixture.result).toBeNil()
	expect(Client._IsInitialized()).toBe(false)
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(Client._IsInitialized()).toBe(true)
	expect(fixture.timeoutCancelled).toBe(true)
	-- The receive path must survive success for subsequent framework messages.
	expect(fixture.listening).toBe(true)
end)

it("installs internal consumers with reconstructed codecs before sending READY", function()
	local installCalls: number = 0
	fixture.dependencies.InstallConsumers = function(
		protocol: SharedNetworkingTypes.ClientProtocol
	): (boolean, string?, (() -> ())?)
		installCalls += 1
		expect(protocol.domainsById["Game.Actions"].id).toBe("Game.Actions")
		expect(protocol.domainsById["Game.Actions"].stateCodec.maxSizeBytes > 0).toBe(true)
		expect(#fixture.sent).toBe(1)
		return true, nil, nil
	end
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	expect(installCalls).toBe(1)
	expect(ProtocolTestUtils.decode(fixture.sent[2]).kind).toBe("Ready")
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
end)

it("handles immediate bootstrap and acknowledgement responses without losing the startup result", function()
	fixture.onSend = function(payload: buffer): ()
		local message: SharedNetworkingTypes.ProtocolMessage = ProtocolTestUtils.decode(payload)
		if message.kind == "Hello" then
			TestUtils.bootstrap(fixture)
		elseif message.kind == "Ready" then
			TestUtils.acknowledge(fixture)
		end
	end
	TestUtils.start(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(fixture.order).toEqual({ "Listen", "Hello", "Consumers", "Ready" })
end)

it("rejects a second attempt while the original attempt is pending without another HELLO", function()
	TestUtils.start(fixture)
	local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Client", reason = "ClientInitAlreadyAttempted" })
	expect(#fixture.sent).toBe(1)
	expect(fixture.result).toBeNil()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
end)

it("rejects a second attempt after success and keeps the established runtime usable", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Client", reason = "ClientInitAlreadyAttempted" })
	expect(#fixture.sent).toBe(2)
	expect(Client._IsInitialized()).toBe(true)
end)

it("ignores a stale timeout after success instead of undoing readiness", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	assert(fixture.timeoutCallback ~= nil, "Expected a bounded handshake timer")
	fixture.timeoutCallback()
	expect(fixture.result).toEqual({ success = true })
	expect(Client._IsInitialized()).toBe(true)
end)
