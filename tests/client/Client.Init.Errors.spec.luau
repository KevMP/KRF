--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Client: ClientTypes.Client = require(KRF.client)
local Compiler: ProtocolTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
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

local function expectInternalFailure(marker: string): ()
	assert(fixture.result ~= nil and fixture.result.failure ~= nil, "Expected an observable startup failure")
	expect(fixture.result.success).toBe(false)
	expect(fixture.result.failure.system).toBe("Networking")
	local prefixStart: number? = string.find(fixture.result.failure.reason, "StartupInternalFailure:", 1, true)
	expect(prefixStart).toBe(1)
	expect(string.find(fixture.result.failure.reason, marker, 1, true) ~= nil).toBe(true)
	expect(Client._IsInitialized()).toBe(false)
end

for _, phase: string in { "discovery", "listener connection", "timeout scheduling", "HELLO send" } do
	it("surfaces unexpected " .. phase .. " failure without leaving startup pending", function()
		if phase == "discovery" then
			fixture.dependencies.DiscoverTransport = function(
				_deadline: number
			): (ClientTypes.ClientTransport?, string?)
				error("AdapterFailure")
			end
		elseif phase == "listener connection" then
			fixture.transport.ConnectReliable = function(_callback: (any, ...any) -> ()): () -> ()
				error("AdapterFailure")
			end
		elseif phase == "timeout scheduling" then
			fixture.dependencies.ScheduleTimeout = function(_seconds: number, _callback: () -> ()): () -> ()
				error("AdapterFailure")
			end
		else
			fixture.transport.SendReliable = function(_payload: buffer): ()
				error("AdapterFailure")
			end
		end
		TestUtils.start(fixture)
		expectInternalFailure("AdapterFailure")
	end)
end

it("surfaces unexpected codec reconstruction failure through the receive boundary", function()
	Compiler.Reconstruct = function(_manifest: ProtocolTypes.ProtocolManifest): (ProtocolTypes.ClientProtocol?, string?)
		error("ReconstructionFailure")
	end
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	expectInternalFailure("ReconstructionFailure")
	expect(fixture.disconnectCalls).toBe(1)
end)

it("surfaces READY send failure and disposes installed consumers", function()
	TestUtils.start(fixture)
	fixture.transport.SendReliable = function(_payload: buffer): ()
		error("ReadySendFailure")
	end
	TestUtils.bootstrap(fixture)
	expectInternalFailure("ReadySendFailure")
	expect(fixture.consumerCleanupCalls).toBe(1)
end)

for _, behavior: string in { "throws", "yields" } do
	it("rejects a private consumer installer that " .. behavior .. " without yielding transport dispatch", function()
		fixture.dependencies.InstallConsumers = function(
			_protocol: ProtocolTypes.ClientProtocol
		): (boolean, string?, (() -> ())?)
			if behavior == "throws" then
				error("InstallerFailure")
			end
			coroutine.yield()
			return true, nil, nil
		end
		TestUtils.start(fixture)
		TestUtils.bootstrap(fixture)
		expectInternalFailure(if behavior == "throws" then "InstallerFailure" else "Yielded")
		expect(#fixture.sent).toBe(1)
	end)
end

it("continues failure cleanup when an installed consumer disposer throws", function()
	local cleanupCalls: number = 0
	fixture.dependencies.InstallConsumers = function(
		_protocol: ProtocolTypes.ClientProtocol
	): (boolean, string?, (() -> ())?)
		return true, nil, function(): ()
			cleanupCalls += 1
			error("CleanupFailure")
		end
	end
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	assert(fixture.timeoutCallback ~= nil, "Expected a scheduled timeout")
	fixture.timeoutCallback()
	TestUtils.expectFailure(fixture, "HandshakeTimeout")
	expect(cleanupCalls).toBe(1)
	expect(fixture.disconnectCalls).toBe(1)
end)

it("maps malformed server rejection and malformed acknowledgement to deterministic startup failures", function()
	TestUtils.start(fixture)
	TestUtils.emit(fixture, ProtocolTestUtils.encode({ kind = "Reject", reason = "MalformedPacket" }))
	TestUtils.expectFailure(fixture, "MalformedBootstrap")
	Client._ResetForTests()
	fixture = TestUtils.new()
	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	local valid: buffer = ProtocolTestUtils.encode({ kind = "ReadyAck" })
	local malformed: buffer = buffer.create(buffer.len(valid) + 1)
	buffer.copy(malformed, 0, valid)
	TestUtils.emit(fixture, malformed)
	TestUtils.expectFailure(fixture, "ReadyRejected")
end)
