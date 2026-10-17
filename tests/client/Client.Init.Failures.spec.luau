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
local Compiler: SharedNetworkingTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local Client: ClientTypes.Client = require(KRF.client)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local fixture: TestUtils.Fixture
local originalReconstruct: typeof(Compiler.Reconstruct) = Compiler.Reconstruct

beforeEach(function()
	Client._ResetForTests()
	fixture = TestUtils.new()
end)
afterEach(function()
	Compiler.Reconstruct = originalReconstruct
	Client._ResetForTests()
	if fixture.initThread ~= nil and coroutine.status(fixture.initThread) ~= "dead" then
		coroutine.close(fixture.initThread)
	end
end)

for _, reason: string in { "TransportUnavailable", "InvalidTransport" } do
	it("returns structured " .. reason .. " from bounded discovery without sending HELLO", function()
		fixture.dependencies.DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
			expect(deadline).toBe(100 + Constants.INIT_TIMEOUT_SECONDS)
			return nil, reason
		end
		TestUtils.start(fixture)
		TestUtils.expectFailure(fixture, reason)
		expect(fixture.sent).toEqual({})
		expect(fixture.listening).toBe(false)
	end)
end

it("fails exact protocol mismatch before reconstructing server schemas", function()
	local reconstructCalls: number = 0
	Compiler.Reconstruct = function(
		_manifest: SharedNetworkingTypes.ProtocolManifest
	): (SharedNetworkingTypes.ClientProtocol?, string?)
		reconstructCalls += 1
		error("Mismatched manifests must not be interpreted")
	end
	TestUtils.start(fixture)
	local compatible: SharedNetworkingTypes.ProtocolManifest = ProtocolTestUtils.manifest()
	local manifest: SharedNetworkingTypes.ProtocolManifest =
		{ version = compatible.version + 1, domains = compatible.domains }
	TestUtils.emit(fixture, ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = manifest }))
	TestUtils.expectFailure(fixture, "ProtocolMismatch")
	expect(reconstructCalls).toBe(0)
	expect(#fixture.sent).toBe(1)
end)

it("fails a truncated bootstrap without publishing codecs or sending READY", function()
	TestUtils.start(fixture)
	local encoded: buffer = ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = ProtocolTestUtils.manifest() })
	local truncated: buffer = buffer.create(buffer.len(encoded) - 1)
	buffer.copy(truncated, 0, encoded, 0, buffer.len(truncated))
	TestUtils.emit(fixture, truncated)
	TestUtils.expectFailure(fixture, "MalformedBootstrap")
	expect(#fixture.sent).toBe(1)
	expect(fixture.disconnectCalls).toBe(1)
	expect(fixture.timeoutCancelled).toBe(true)
end)

it("distinguishes unsupported schema reconstruction from malformed bootstrap", function()
	Compiler.Reconstruct = function(
		_manifest: SharedNetworkingTypes.ProtocolManifest
	): (SharedNetworkingTypes.ClientProtocol?, string?)
		return nil, "UnsupportedSchema"
	end
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "UnsupportedSchema")
	expect(#fixture.sent).toBe(1)
	expect(fixture.disconnectCalls).toBe(1)
end)

it("fails oversized bootstrap before compiling schemas", function()
	TestUtils.start(fixture)
	local encoded: buffer = ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = ProtocolTestUtils.manifest() })
	local oversized: buffer = buffer.create(Constants.MAX_BOOTSTRAP_BYTES + 1)
	buffer.copy(oversized, 0, encoded)
	TestUtils.emit(fixture, oversized)
	TestUtils.expectFailure(fixture, "BootstrapTooLarge")
	expect(#fixture.sent).toBe(1)
end)

for _, phase: string in { "awaiting bootstrap", "awaiting acknowledgement" } do
	it("times out while " .. phase .. " and cleans pending startup exactly once", function()
		TestUtils.start(fixture)
		if phase == "awaiting acknowledgement" then
			TestUtils.bootstrap(fixture)
		end
		expect(fixture.timeoutSeconds ~= nil and (fixture.timeoutSeconds :: number) > 0).toBe(true)
		assert(fixture.timeoutCallback ~= nil, "Expected bounded timeout")
		fixture.timeoutCallback()
		TestUtils.expectFailure(fixture, "HandshakeTimeout")
		expect(fixture.disconnectCalls).toBe(1)
		expect(fixture.timeoutCancelled).toBe(true)
		expect(fixture.consumerCleanupCalls).toBe(if phase == "awaiting acknowledgement" then 1 else 0)
		fixture.timeoutCallback()
		expect(fixture.disconnectCalls).toBe(1)
	end)
end

it("rejects READY_ACK before bootstrap instead of treating any acknowledgement as success", function()
	TestUtils.start(fixture)
	TestUtils.acknowledge(fixture)
	TestUtils.expectFailure(fixture, "ReadyRejected")
	expect(#fixture.sent).toBe(1)
end)

it("surfaces explicit server rejection while awaiting READY_ACK", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.emit(fixture, ProtocolTestUtils.encode({ kind = "Reject", reason = "ReadyRejected" }))
	TestUtils.expectFailure(fixture, "ReadyRejected")
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

it("fails a private consumer installation failure before sending READY", function()
	fixture.dependencies.InstallConsumers = function(
		_protocol: SharedNetworkingTypes.ClientProtocol
	): (boolean, string?, (() -> ())?)
		return false, "InternalConsumerInitializationFailed", nil
	end
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "InternalConsumerInitializationFailed")
	expect(#fixture.sent).toBe(1)
	expect(fixture.disconnectCalls).toBe(1)
end)

it("rejects a second attempt after failure without discovering transports again", function()
	local discoveries: number = 0
	fixture.dependencies.DiscoverTransport = function(_deadline: number): (ClientTypes.ClientTransport?, string?)
		discoveries += 1
		return nil, "TransportUnavailable"
	end
	TestUtils.start(fixture)
	TestUtils.expectFailure(fixture, "TransportUnavailable")
	local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Client", reason = "ClientInitAlreadyAttempted" })
	expect(discoveries).toBe(1)
end)

it("cannot be revived by a late acknowledgement after startup timeout", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	assert(fixture.timeoutCallback ~= nil, "Expected timeout")
	fixture.timeoutCallback()
	-- Retain the disconnected callback to simulate an already queued delivery.
	TestUtils.acknowledge(fixture)
	TestUtils.expectFailure(fixture, "HandshakeTimeout")
	expect(fixture.disconnectCalls).toBe(1)
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

for _, inputKind: string in { "non-buffer payload", "unknown opcode", "positional bootstrap arguments" } do
	it("rejects " .. inputKind .. " without throwing or dispatching valid bootstrap work", function()
		TestUtils.start(fixture)
		local payload: any = {}
		if inputKind == "unknown opcode" then
			payload = buffer.create(1)
			buffer.writeu8(payload, 0, 255)
		elseif inputKind == "positional bootstrap arguments" then
			payload = ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = ProtocolTestUtils.manifest() })
		end
		local completed: boolean = pcall(function()
			if inputKind == "positional bootstrap arguments" then
				TestUtils.emit(fixture, payload, { extra = true })
			else
				TestUtils.emit(fixture, payload)
			end
		end)
		expect(completed).toBe(true)
		expect(Client._IsInitialized()).toBe(false)
		expect(#fixture.sent).toBe(1)
		if fixture.result ~= nil then
			expect(fixture.result.success).toBe(false)
		end
	end)
end

it("does not reinstall consumers or send READY again for a duplicate bootstrap", function()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	TestUtils.bootstrap(fixture)
	expect(#fixture.sent).toBe(2)
	expect(Client._IsInitialized()).toBe(false)
	local installCalls: number = 0
	for _, step: string in fixture.order do
		if step == "Consumers" then
			installCalls += 1
		end
	end
	expect(installCalls).toBe(1)
end)
