--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Transport: SharedNetworkingTypes.Transport = require(KRF.shared.Networking.Transport)
local ProtocolTestUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalLocate: typeof(Transport.Locate) = Transport.Locate
local instances: { Instance } = {}
local cancellations: { () -> () } = {}

afterEach(function()
	Client._ResetForTests()
	Transport.Locate = originalLocate

	for _, cancel: () -> () in cancellations do
		cancel()
	end

	cancellations = {}

	for _, instance: Instance in instances do
		instance:Destroy()
	end

	instances = {}
end)

local function event(): BindableEvent
	local signal: BindableEvent = Instance.new("BindableEvent")
	table.insert(instances, signal)

	return signal
end

local function mockTransport(signal: BindableEvent, send: (buffer) -> ()): SharedNetworkingTypes.OwnedTransport
	local root: Folder = Instance.new("Folder")
	table.insert(instances, root)

	local reliable: any = {
		OnClientEvent = signal.Event,
		FireServer = function(_self: any, payload: buffer): ()
			send(payload)
		end,
	}

	return { root = root, reliable = reliable, unreliable = {} :: any, Destroy = function(): () end }
end

for _, reason: string in { "TransportUnavailable", "InvalidTransport" } do
	it("returns " .. reason .. " once the native discovery deadline is exhausted", function()
		Transport.Locate = function(_parent: Instance): (SharedNetworkingTypes.OwnedTransport?, string?)
			return nil, reason
		end

		local endpoint: ClientTypes.ClientTransport?, failure: string? = Native.DiscoverTransport(Native.Now() - 1)
		expect(endpoint).toBeNil()
		expect(failure).toBe(reason)
	end)
end

it(
	"discovers transports that become complete after replication and forwards buffers through the native adapter",
	function()
		local inbound: BindableEvent = event()
		local delivered: BindableEvent = event()
		local sent: buffer? = nil

		local owned: SharedNetworkingTypes.OwnedTransport = mockTransport(inbound, function(payload: buffer): ()
			sent = payload
		end)

		local calls: number = 0

		Transport.Locate = function(_parent: Instance): (SharedNetworkingTypes.OwnedTransport?, string?)
			calls += 1

			return if calls == 1 then nil else owned, if calls == 1 then "InvalidTransport" else nil
		end

		local endpoint: ClientTypes.ClientTransport?, reason: string? = Native.DiscoverTransport(Native.Now() + 1)
		expect(reason).toBeNil()
		assert(endpoint ~= nil, "Expected discovered native endpoint")
		expect(calls).toBe(2)
		local received: any = nil

		local disconnect: () -> () = endpoint.ConnectReliable(function(payload: any): ()
			received = payload
			delivered:Fire()
		end)

		local payload: buffer = buffer.fromstring("buffer payload")
		endpoint.SendReliable(payload)
		expect(sent).toBe(payload)

		task.defer(function(): ()
			inbound:Fire(payload)
		end)

		delivered.Event:Wait()
		expect(buffer.tostring(received)).toBe(buffer.tostring(payload))
		disconnect()
		disconnect()
		local barrier: BindableEvent = event()
		inbound:Fire(buffer.create(0))

		task.defer(function(): ()
			barrier:Fire()
		end)

		barrier.Event:Wait()
		expect(buffer.tostring(received)).toBe(buffer.tostring(payload))
	end
)

it("defers the startup caller until after the native transport callback has returned", function()
	local delivered: BindableEvent = event()
	local order: { string } = {}

	local waitingThread: thread = coroutine.create(function(): ()
		table.insert(order, "Consumer")
		delivered:Fire()
	end)

	Native.Resume(waitingThread)
	table.insert(order, "CallbackReturned")
	delivered.Event:Wait()
	expect(order).toEqual({ "CallbackReturned", "Consumer" })
end)

it("fires a native timeout once and permits cancellation from its own callback", function()
	local delivered: BindableEvent = event()
	local calls: number = 0
	local cancel: () -> () = function(): () end

	cancel = Native.ScheduleTimeout(0, function(): ()
		calls += 1
		cancel()
		delivered:Fire()
	end)

	table.insert(cancellations, cancel)
	delivered.Event:Wait()
	cancel()
	cancel()
	expect(calls).toBe(1)
end)

it("cancels a scheduled native timeout before its callback can run", function()
	local delivered: BindableEvent = event()
	local calls: number = 0

	local cancel: () -> () = Native.ScheduleTimeout(0, function(): ()
		calls += 1
	end)

	table.insert(cancellations, cancel)
	cancel()
	cancel()

	task.defer(function(): ()
		delivered:Fire()
	end)

	delivered.Event:Wait()
	expect(calls).toBe(0)
end)

it("completes Client.Init with the default adapter and native deferred resumption", function()
	Client._ResetForTests()
	local inbound: BindableEvent = event()
	local finished: BindableEvent = event()

	local owned: SharedNetworkingTypes.OwnedTransport = mockTransport(inbound, function(payload: buffer): ()
		local message: SharedNetworkingTypes.ProtocolMessage = ProtocolTestUtils.decode(payload)

		if message.kind == "Hello" then
			inbound:Fire(ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = ProtocolTestUtils.manifest() }))
		elseif message.kind == "Ready" then
			inbound:Fire(ProtocolTestUtils.encode({ kind = "ReadyAck" }))
		end
	end)

	Transport.Locate = function(_parent: Instance): (SharedNetworkingTypes.OwnedTransport?, string?)
		return owned, nil
	end

	local result: boolean? = nil
	local failure: ClientTypes.StartupFailure? = nil

	task.defer(function(): ()
		result, failure = Client.Init()
		finished:Fire()
	end)

	finished.Event:Wait()
	expect(result).toBe(true)
	expect(failure).toBeNil()
	expect(Client._IsInitialized()).toBe(true)
end)
