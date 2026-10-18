--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local PublicTypes = require(KRF.client.Actor.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Runtime: ClientNetworkingTypes.ActorViewRuntimeModule = require(KRF.client.Networking.ActorViewRuntime)
local Stream: ClientNetworkingTypes.ActorStreamRuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Discovery: ClientNetworkingTypes.ActorModelDiscoveryModule =
	require(KRF.client.Networking.utils.ActorModelDiscovery)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Consumer = require(KRF.client.Networking.utils.ActorStreamConsumer)
local ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local ResyncCodec = require(KRF.shared.Networking.utils.ResyncCodec)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalNew: typeof(Runtime.new) = Runtime.new
local originalStream: typeof(Stream.new) = Stream.new
local originalDiscovery: typeof(Discovery.new) = Discovery.new
local originalNow: typeof(Native.Now) = Native.Now
local originalDiscover: typeof(Native.DiscoverTransport) = Native.DiscoverTransport
local originalSchedule: typeof(Native.ScheduleTimeout) = Native.ScheduleTimeout
local originalResume: typeof(Native.Resume) = Native.Resume
local fixture: TestUtils.Fixture
local stream: StreamUtils.Fixture
local created: number
local destroyed: number
local resync: { buffer }

beforeEach(function()
	Client._ResetForTests()
	Consumer.Install(nil)
	fixture = TestUtils.new()
	stream = StreamUtils.new()
	created = 0
	destroyed = 0
	resync = {}
	Native.Now = fixture.dependencies.Now
	Native.DiscoverTransport = fixture.dependencies.DiscoverTransport
	Native.ScheduleTimeout = fixture.dependencies.ScheduleTimeout
	Native.Resume = fixture.dependencies.Resume
	local originalSend: (buffer) -> () = fixture.transport.SendReliable
	fixture.transport.SendReliable = function(payload: buffer)
		local message: SharedNetworkingTypes.ProtocolMessage? = ProtocolCodec.Decode(payload)
		if message ~= nil then
			originalSend(payload)
		else
			table.insert(resync, payload)
		end
	end
	Discovery.new = function(_root: Instance?): ClientNetworkingTypes.ActorModelDiscoveryAdapter
		return {
			GetCandidates = stream.discovery.GetCandidates,
			ObserveAdded = stream.discovery.ObserveAdded,
			ObserveRemoved = stream.discovery.ObserveRemoved,
			Destroy = function(): () end,
		}
	end
	Runtime.new = function(
		protocol: SharedNetworkingTypes.ClientProtocol,
		schemas: SharedNetworkingTypes.ActorSchemaCatalog,
		options: ClientNetworkingTypes.ActorViewOptions
	): ClientNetworkingTypes.ActorViewRuntime
		created += 1
		table.insert(fixture.order, "ActorViews")
		local runtime: ClientNetworkingTypes.ActorViewRuntime = originalNew(protocol, schemas, options)
		local destroy: typeof(runtime.Destroy) = runtime.Destroy
		runtime.Destroy = function(self: ClientNetworkingTypes.ActorViewRuntime)
			destroyed += 1
			destroy(self)
		end
		return runtime
	end
end)
afterEach(function()
	Client._ResetForTests()
	Consumer.Install(nil)
	if fixture.initThread ~= nil and coroutine.status(fixture.initThread) ~= "dead" then
		coroutine.close(fixture.initThread)
	end
	Runtime.new = originalNew
	Stream.new = originalStream
	Discovery.new = originalDiscovery
	Native.Now = originalNow
	Native.DiscoverTransport = originalDiscover
	Native.ScheduleTimeout = originalSchedule
	Native.Resume = originalResume
	StreamUtils.destroy(stream)
end)

local function start(): ()
	fixture.initThread = coroutine.create(function()
		local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
		fixture.result = { success = success, failure = failure }
	end)
	local completed: boolean, reason: any = coroutine.resume(fixture.initThread :: thread)
	expect(completed).toBe(true)
	expect(reason).toBeNil()
end

local function baseline(): buffer
	local body: buffer = StreamUtils.body(stream)
	local payload: buffer?, reason: string? = stream.codec.Encode({
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})
	assert(payload ~= nil, reason)
	return payload
end

it("constructs the real N5 consumer automatically before READY and succeeds with an empty public registry", function()
	start()
	TestUtils.bootstrap(fixture)
	expect(created).toBe(1)
	expect(fixture.order).toEqual({ "Listen", "Hello", "ActorViews", "Ready" })
	expect(Registry.GetAllActorViews()).toEqual({})
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(destroyed).toBe(0)
end)

it("consumes immediate ACK-following Actor traffic through the default receive path and public registry", function()
	fixture.onSend = function(payload: buffer)
		if ProtocolUtils.decode(payload).kind == "Ready" then
			TestUtils.acknowledge(fixture)
			TestUtils.emit(fixture, baseline())
		end
	end
	start()
	TestUtils.bootstrap(fixture)
	expect(fixture.result).toEqual({ success = true })
	local view: PublicTypes.ActorView? = Registry.GetActorViewById("ActorA")
	assert(view ~= nil, "Production startup must install N5 before immediate Actor traffic")
	expect(view:GetId()).toBe("ActorA")
	local domain: PublicTypes.DomainView? = view:GetDomain("Game.Actions")
	assert(domain ~= nil, "Expected bootstrap-defined game domain")
	expect(domain:GetState()).toEqual({ active = false, mode = "Idle" })
end)

it("creates a later ActorView after successful Init and sends resync over the installed Reliable endpoint", function()
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	expect(Registry.GetAllActorViews()).toEqual({})
	TestUtils.emit(fixture, baseline())
	local view: PublicTypes.ActorView? = Registry.GetActorViewById("ActorA")
	assert(view ~= nil, "Expected future baseline publication")
	local gap: buffer?, reason: string? =
		stream.codec.Encode({ { kind = "Commit", handle = 1, revision = 3, patches = {}, events = {} } })
	assert(gap ~= nil, reason)
	TestUtils.emit(fixture, gap)
	expect(#resync).toBe(1)
	local request: ResyncCodec.Request? = ResyncCodec.Decode(resync[1])
	expect(request).toEqual({ handle = 1 })
end)

for _, failure: string in { "ReadyRejected", "HandshakeTimeout", "ClientReset" } do
	it("cleans the pre-READY N5 runtime exactly once on " .. failure, function()
		start()
		TestUtils.bootstrap(fixture)
		expect(created).toBe(1)
		if failure == "ReadyRejected" then
			TestUtils.emit(fixture, ProtocolUtils.encode({ kind = "Reject", reason = "ReadyRejected" }))
		elseif failure == "HandshakeTimeout" then
			assert(fixture.timeoutCallback ~= nil, "Expected timeout")
			fixture.timeoutCallback()
		else
			Client._ResetForTests()
		end
		TestUtils.expectFailure(fixture, failure)
		Client._ResetForTests()
		expect(destroyed).toBe(1)
		expect(Registry.GetAllActorViews()).toEqual({})
	end)
end

it("cleans public membership and disconnects retained receives when a successful client resets", function()
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	TestUtils.emit(fixture, baseline())
	expect(#Registry.GetAllActorViews()).toBe(1)
	Client._ResetForTests()
	Client._ResetForTests()
	TestUtils.emit(fixture, baseline())
	expect(Registry.GetAllActorViews()).toEqual({})
	expect(destroyed).toBe(1)
end)

it("sends no READY and releases N4 discovery if N5 construction fails", function()
	Runtime.new = function(
		_protocol: SharedNetworkingTypes.ClientProtocol,
		_schemas: SharedNetworkingTypes.ActorSchemaCatalog,
		_options: ClientNetworkingTypes.ActorViewOptions
	): ClientNetworkingTypes.ActorViewRuntime
		error("ForcedActorViewConstructionFailure", 0)
	end
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "StartupInternalFailure:ForcedActorViewConstructionFailure")
	expect(fixture.order).toEqual({ "Listen", "Hello" })
	expect(#stream.added).toBe(0)
	expect(#stream.gone).toBe(0)
end)

it("reports malformed Actor framing once through the native reporter and continues valid production traffic", function()
	local faults: { string } = {}
	Stream.new = function(
		codec: SharedNetworkingTypes.ActorStreamCodec,
		consumer: ClientNetworkingTypes.ActorStreamConsumer?,
		discovery: ClientNetworkingTypes.ActorModelDiscovery,
		options: ClientNetworkingTypes.ActorStreamOptions
	): ClientNetworkingTypes.ActorStreamRuntime
		local report: (string) -> () = options.ReportFault
		options.ReportFault = function(reason: string)
			table.insert(faults, reason)
			report(reason)
		end
		return originalStream(codec, consumer, discovery, options)
	end
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	local malformed: buffer = buffer.create(1)
	buffer.writeu8(malformed, 0, 64)
	TestUtils.emit(fixture, malformed)
	expect(faults).toEqual({ "MalformedActorPacket" })
	expect(Registry.GetAllActorViews()).toEqual({})
	TestUtils.emit(fixture, baseline())
	local view: PublicTypes.ActorView? = Registry.GetActorViewById("ActorA")
	assert(view ~= nil, "Framing rejection must not disable unrelated future traffic")
	expect(view:IsAvailable()).toBe(true)
	expect(faults).toEqual({ "MalformedActorPacket" })
end)
