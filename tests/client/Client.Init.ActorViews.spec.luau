--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local Types = require(KRF.client.Networking.ActorViewTypes)
local PublicTypes = require(KRF.client.Actor.types)
local StreamTypes = require(KRF.client.Networking.ActorStreamTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local Client: ClientTypes.Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.NativeClientDependencies)
local Runtime: Types.RuntimeModule = require(KRF.client.Networking.ActorViewRuntime)
local Discovery: StreamTypes.DiscoveryModule = require(KRF.client.Networking.ActorModelDiscovery)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Consumer = require(KRF.client.Networking.ActorStreamConsumer)
local ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local ResyncCodec = require(KRF.shared.Networking.ResyncCodec)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalNew: typeof(Runtime.new) = Runtime.new
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
		local message: ProtocolTypes.Message? = ProtocolCodec.Decode(payload)
		if message ~= nil then
			originalSend(payload)
		else
			table.insert(resync, payload)
		end
	end
	Discovery.new = function(_root: Instance?): StreamTypes.DiscoveryAdapter
		return {
			GetCandidates = stream.discovery.GetCandidates,
			ObserveAdded = stream.discovery.ObserveAdded,
			ObserveRemoved = stream.discovery.ObserveRemoved,
			Destroy = function(): () end,
		}
	end
	Runtime.new = function(
		protocol: ProtocolTypes.ClientProtocol,
		schemas: WireTypes.SchemaCatalog,
		options: Types.Options
	): Types.Runtime
		created += 1
		table.insert(fixture.order, "ActorViews")
		local runtime: Types.Runtime = originalNew(protocol, schemas, options)
		local destroy: typeof(runtime.Destroy) = runtime.Destroy
		runtime.Destroy = function(self: Types.Runtime)
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
		_protocol: ProtocolTypes.ClientProtocol,
		_schemas: WireTypes.SchemaCatalog,
		_options: Types.Options
	): Types.Runtime
		error("ForcedActorViewConstructionFailure", 0)
	end
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "StartupInternalFailure:ForcedActorViewConstructionFailure")
	expect(fixture.order).toEqual({ "Listen", "Hello" })
	expect(#stream.added).toBe(0)
	expect(#stream.gone).toBe(0)
end)
