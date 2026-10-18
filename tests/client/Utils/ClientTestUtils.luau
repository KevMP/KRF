--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ClientTypes = require(KRF.client.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Client: ClientTypes.Client = require(KRF.client)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

export type InitResult = { success: boolean, failure: ClientTypes.StartupFailure? }

export type Fixture = {
	dependencies: ClientTypes.Dependencies,
	transport: ClientTypes.ClientTransport,
	listening: boolean,
	disconnectCalls: number,
	consumerCleanupCalls: number,
	timeoutCancelled: boolean,
	timeoutSeconds: number?,
	timeoutCallback: (() -> ())?,
	inbound: ((any, ...any) -> ())?,
	onSend: ((buffer) -> ())?,
	sent: { buffer },
	order: { string },
	result: InitResult?,
	initThread: thread?,
}

local ClientTestUtils = {}

function ClientTestUtils.new(): Fixture
	local fixture: Fixture = {
		dependencies = {} :: ClientTypes.Dependencies,
		transport = {} :: ClientTypes.ClientTransport,
		listening = false,
		disconnectCalls = 0,
		consumerCleanupCalls = 0,
		timeoutCancelled = false,
		sent = {},
		order = {},
	}

	fixture.transport = {
		ConnectReliable = function(callback: (any, ...any) -> ()): () -> ()
			fixture.listening = true
			fixture.inbound = callback
			table.insert(fixture.order, "Listen")

			return function(): ()
				fixture.disconnectCalls += 1
				fixture.listening = false
			end
		end,
		SendReliable = function(payload: buffer): ()
			expect(fixture.listening).toBe(true)
			expect(typeof(payload)).toBe("buffer")
			table.insert(fixture.sent, payload)
			table.insert(fixture.order, ProtocolTestUtils.decode(payload).kind)

			if fixture.onSend ~= nil then
				fixture.onSend(payload)
			end
		end,
	}

	fixture.dependencies = {
		Now = function(): number
			return 100
		end,
		Resume = function(waitingThread: thread): ()
			local completed: boolean, reason: any = coroutine.resume(waitingThread)

			if not completed then
				error(tostring(reason), 2)
			end
		end,
		DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
			expect(deadline > 100 and deadline < math.huge).toBe(true)

			return fixture.transport, nil
		end,
		ScheduleTimeout = function(seconds: number, callback: () -> ()): () -> ()
			fixture.timeoutSeconds = seconds
			fixture.timeoutCallback = callback

			return function(): ()
				fixture.timeoutCancelled = true
			end
		end,
		InstallConsumers = function(_protocol: SharedNetworkingTypes.ClientProtocol): (boolean, string?, (() -> ())?)
			table.insert(fixture.order, "Consumers")

			return true, nil, function(): ()
				fixture.consumerCleanupCalls += 1
			end
		end,
	}

	return fixture
end

function ClientTestUtils.start(fixture: Fixture): ()
	Client._SetDependenciesForTests(fixture.dependencies)

	local initThread: thread = coroutine.create(function()
		local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init()
		fixture.result = { success = success, failure = failure }
	end)

	fixture.initThread = initThread
	local completed: boolean, reason: any = coroutine.resume(initThread)
	expect(completed).toBe(true)

	if not completed then
		error(tostring(reason), 2)
	end
end

function ClientTestUtils.emit(fixture: Fixture, payload: any, ...: any): ()
	assert(fixture.inbound ~= nil, "Expected connected inbound listener")
	fixture.inbound(payload, ...)
end

function ClientTestUtils.bootstrap(fixture: Fixture): ()
	ClientTestUtils.emit(
		fixture,
		ProtocolTestUtils.encode({ kind = "Bootstrap", manifest = ProtocolTestUtils.manifest() })
	)
end

function ClientTestUtils.acknowledge(fixture: Fixture): ()
	ClientTestUtils.emit(fixture, ProtocolTestUtils.encode({ kind = "ReadyAck" }))
end

function ClientTestUtils.expectFailure(fixture: Fixture, reason: string): ()
	assert(fixture.result ~= nil, "Expected completed initialization")
	expect(fixture.result.success).toBe(false)
	expect(fixture.result.failure).toEqual({ system = "Networking", reason = reason })
	expect(Client._IsInitialized()).toBe(false)
end

return ClientTestUtils
