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
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Stream: ClientNetworkingTypes.ActorStreamRuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Discovery: ClientNetworkingTypes.ActorModelDiscoveryModule =
	require(KRF.client.Networking.utils.ActorModelDiscovery)
local TestUtils = require(script.Parent.Utils.ClientTestUtils)
local StreamTestUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalNew: typeof(Stream.new) = Stream.new
local originalDiscovery: typeof(Discovery.new) = Discovery.new
local originalNow: typeof(Native.Now) = Native.Now
local originalDiscover: typeof(Native.DiscoverTransport) = Native.DiscoverTransport
local originalSchedule: typeof(Native.ScheduleTimeout) = Native.ScheduleTimeout
local originalResume: typeof(Native.Resume) = Native.Resume
local fixture: TestUtils.Fixture
local created: number = 0
local destroyed: number = 0
local discoveryDestroyed: number = 0
local deliveries: { buffer } = {}
local discovery: ClientNetworkingTypes.ActorModelDiscoveryAdapter

beforeEach(function()
	Client._ResetForTests()
	fixture = TestUtils.new()
	created = 0
	destroyed = 0
	discoveryDestroyed = 0
	deliveries = {}
	-- Keep the production installer intact. Only platform I/O, clock and resume are controlled.
	Native.Now = fixture.dependencies.Now
	Native.DiscoverTransport = fixture.dependencies.DiscoverTransport
	Native.ScheduleTimeout = fixture.dependencies.ScheduleTimeout
	Native.Resume = fixture.dependencies.Resume
	discovery = {
		GetCandidates = function(): { ClientNetworkingTypes.ActorModelCandidate }
			return {}
		end,
		ObserveAdded = function(_callback: (ClientNetworkingTypes.ActorModelCandidate) -> ()): () -> ()
			return function(): () end
		end,
		ObserveRemoved = function(_callback: (Instance) -> ()): () -> ()
			return function(): () end
		end,
		Destroy = function(): ()
			discoveryDestroyed += 1
		end,
	}
	Discovery.new = function(_root: Instance?): ClientNetworkingTypes.ActorModelDiscoveryAdapter
		return discovery
	end
	Stream.new = function(
		_codec: SharedNetworkingTypes.ActorStreamCodec,
		_consumer: ClientNetworkingTypes.ActorStreamConsumer?,
		installedDiscovery: ClientNetworkingTypes.ActorModelDiscovery,
		_options: ClientNetworkingTypes.ActorStreamOptions
	): ClientNetworkingTypes.ActorStreamRuntime
		created += 1
		expect(installedDiscovery).toBe(discovery)
		table.insert(fixture.order, "ActorConsumers")
		return {
			Handle = function(_self: ClientNetworkingTypes.ActorStreamRuntime, payload: any): (boolean, string?)
				expect(typeof(payload)).toBe("buffer")
				table.insert(deliveries, payload)
				return true, nil
			end,
			GetByHandle = function(
				_self: ClientNetworkingTypes.ActorStreamRuntime,
				_handle: number
			): ClientNetworkingTypes.ActorStreamRecord?
				return nil
			end,
			GetByActorId = function(
				_self: ClientNetworkingTypes.ActorStreamRuntime,
				_actorId: string
			): ClientNetworkingTypes.ActorStreamRecord?
				return nil
			end,
			GetByModel = function(
				_self: ClientNetworkingTypes.ActorStreamRuntime,
				_model: Model
			): ClientNetworkingTypes.ActorStreamRecord?
				return nil
			end,
			Destroy = function(_self: ClientNetworkingTypes.ActorStreamRuntime): ()
				destroyed += 1
			end,
		}
	end
end)
afterEach(function()
	Client._ResetForTests()
	if fixture.initThread ~= nil and coroutine.status(fixture.initThread) ~= "dead" then
		coroutine.close(fixture.initThread)
	end
	Stream.new = originalNew
	Discovery.new = originalDiscovery
	Native.Now = originalNow
	Native.DiscoverTransport = originalDiscover
	Native.ScheduleTimeout = originalSchedule
	Native.Resume = originalResume
end)

local function start(): ()
	-- No _SetDependenciesForTests: Client.Init selects its production native dependency table.
	local initThread: thread = coroutine.create(function(): ()
		local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
		fixture.result = { success = success, failure = failure }
	end)
	fixture.initThread = initThread
	local completed: boolean, reason: any = coroutine.resume(initThread)
	expect(completed).toBe(true)
	expect(reason).toBeNil()
end

it("installs N4 through the production consumer phase before sending READY", function()
	start()
	TestUtils.bootstrap(fixture)
	expect(created).toBe(1)
	expect(fixture.order).toEqual({ "Listen", "Hello", "ActorConsumers", "Ready" })
	expect(fixture.result).toBeNil()
	expect(deliveries).toEqual({})
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(destroyed).toBe(0)
end)

it("continues routing Reliable Actor buffers after READY_ACK finishes Client.Init", function()
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	-- The real N4 codec produces Actor packets using the same catalog as the bootstrap.
	local actorFixture: StreamTestUtils.Fixture = StreamTestUtils.new()
	local body: buffer = StreamTestUtils.body(actorFixture)
	local first: buffer?, firstReason: string? = actorFixture.codec.Encode({
		{ kind = "BaselineBegin", handle = 1, actorId = "ActorA", generation = 1, totalBytes = buffer.len(body) },
		{ kind = "BaselineChunk", handle = 1, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = 1, generation = 1, revision = 1 },
	})
	expect(firstReason).toBeNil()
	assert(first ~= nil, "Expected real baseline packet")
	local second: buffer?, secondReason: string? = actorFixture.codec.Encode({
		{
			kind = "Commit",
			handle = 1,
			revision = 2,
			patches = {
				{
					domainId = "Game.Actions",
					patch = { kind = "Struct", fields = { active = { kind = "Replace", value = true } } },
				},
			},
			events = {},
		},
	})
	expect(secondReason).toBeNil()
	assert(second ~= nil, "Expected real live Actor packet")
	TestUtils.emit(fixture, first)
	TestUtils.emit(fixture, second)
	expect(#deliveries).toBe(2)
	expect(deliveries[1]).toBe(first)
	expect(deliveries[2]).toBe(second)
	expect(created).toBe(1)
	expect(destroyed).toBe(0)
end)

it("destroys N4 once on reset and stops routing even a retained Reliable callback", function()
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.acknowledge(fixture)
	expect(created).toBe(1)
	Client._ResetForTests()
	Client._ResetForTests()
	expect(destroyed).toBe(1)
	expect(discoveryDestroyed).toBe(1)
	expect(fixture.listening).toBe(false)
	TestUtils.emit(fixture, buffer.fromstring("Retained Actor callback"))
	expect(deliveries).toEqual({})
end)

for _, failure: string in { "ReadyRejected", "HandshakeTimeout", "ClientReset" } do
	it("destroys the pre-READY Actor runtime when startup ends with " .. failure, function()
		start()
		TestUtils.bootstrap(fixture)
		expect(created).toBe(1)
		if failure == "ReadyRejected" then
			TestUtils.emit(fixture, ProtocolUtils.encode({ kind = "Reject", reason = "ReadyRejected" }))
		elseif failure == "HandshakeTimeout" then
			assert(fixture.timeoutCallback ~= nil, "Expected scheduled startup timeout")
			fixture.timeoutCallback()
		else
			Client._ResetForTests()
		end
		TestUtils.expectFailure(fixture, failure)
		expect(destroyed).toBe(1)
		expect(discoveryDestroyed).toBe(1)
		expect(fixture.listening).toBe(false)
		Client._ResetForTests()
		expect(destroyed).toBe(1)
	end)
end

it("destroys the installed Actor runtime when READY transmission throws", function()
	fixture.onSend = function(payload: buffer): ()
		local message: SharedNetworkingTypes.ProtocolMessage = ProtocolUtils.decode(payload)
		if message.kind == "Ready" then
			error("ForcedReadySendFailure", 0)
		end
	end
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "StartupInternalFailure:ForcedReadySendFailure")
	expect(created).toBe(1)
	expect(destroyed).toBe(1)
	expect(discoveryDestroyed).toBe(1)
end)

it("rolls back discovery and sends no READY when Actor runtime construction fails", function()
	Stream.new = function(
		_codec: SharedNetworkingTypes.ActorStreamCodec,
		_consumer: ClientNetworkingTypes.ActorStreamConsumer?,
		_discovery: ClientNetworkingTypes.ActorModelDiscovery,
		_options: ClientNetworkingTypes.ActorStreamOptions
	): ClientNetworkingTypes.ActorStreamRuntime
		error("ForcedActorStreamConstructionFailure", 0)
	end
	start()
	TestUtils.bootstrap(fixture)
	TestUtils.expectFailure(fixture, "StartupInternalFailure:ForcedActorStreamConstructionFailure")
	expect(fixture.order).toEqual({ "Listen", "Hello" })
	expect(discoveryDestroyed).toBe(1)
	expect(fixture.listening).toBe(false)
end)
