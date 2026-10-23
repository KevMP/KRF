--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Client = require(KRF.client)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local NetworkingTypes = require(KRF.client.Networking.types)
local Commands: NetworkingTypes.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	fixture.cleanup()
end)

local function expectReadOnlyEvent(publicEvent: SignalTypes.Event<any>): ()
	local event: any = publicEvent
	expect(type(event.Connect)).toBe("function")
	expect(type(event.Once)).toBe("function")
	expect(type(event.Wait)).toBe("function")
	local connection: SignalTypes.Connection = event:Connect(function() end)
	connection:Disconnect()
	local once: SignalTypes.Connection = event:Once(function() end)
	once:Disconnect()

	-- Match SignalModule.wrapEvent's strict read-only surface. Its methods
	-- live behind a metatable; table freezing is not the Event contract.
	for _, member: string in { "Fire", "Destroy", "DisconnectAll", "NotARealMember" } do
		expect(function()
			local _: any = event[member]
		end).toThrow()
	end

	expect(function()
		event.Connect = function() end
	end).toThrow()

	expect(function()
		event.NotARealMember = true
	end).toThrow()
end

local function expectNotAdmitted(runtime: NetworkingTypes.CommandRuntime): ()
	local sentBefore: number = #fixture.sent
	local requestId: number?, reason: string? = runtime.Send("Game.Ping")
	expect(requestId).toBeNil()
	expect(type(reason)).toBe("string")
	assert(reason ~= nil, "Local failure must have a reason")
	expect(#reason > 0).toBe(true)
	expect(#fixture.sent).toBe(sentBefore)
end

it("rejects Send before Init, during bootstrap and while READY is awaiting acknowledgement", function()
	local runtime: NetworkingTypes.CommandRuntime = Commands
	expectNotAdmitted(runtime)
	TestUtils.start(fixture)
	expectNotAdmitted(runtime)
	TestUtils.bootstrap(fixture)
	expect(fixture.client.result).toBeNil()
	expectNotAdmitted(runtime)
	ClientUtils.acknowledge(fixture.client)
	expect(fixture.client.result).toEqual({ success = true })
	local requestId: number?, reason: string? = runtime.Send("Game.Ping")
	expect(reason).toBeNil()
	expect(type(requestId)).toBe("number")
	expect(#fixture.sent).toBe(1)
end)

it("installs command events before READY and admits Send immediately after ACK through the native installer", function()
	local runtime: NetworkingTypes.CommandRuntime = Commands
	local observed: number? = nil

	fixture.client.onSend = function(payload: buffer): ()
		if ProtocolUtils.decode(payload).kind == "Ready" then
			expect(type(runtime.OnCommandResult.Connect)).toBe("function")
			expect(type(runtime.OnCommandUncertain.Connect)).toBe("function")
			expectNotAdmitted(runtime)
			ClientUtils.acknowledge(fixture.client)
			local reason: string? = nil
			observed, reason = runtime.Send("Game.Ping")
			expect(reason).toBeNil()
		end
	end

	TestUtils.start(fixture)
	TestUtils.bootstrap(fixture)
	expect(fixture.client.result).toEqual({ success = true })
	expect(type(observed)).toBe("number")
	expect(#fixture.sent).toBe(1)
end)

it(
	"keeps real Actor baseline and live commit reception working beside command Send on one Reliable listener",
	function()
		local runtime: NetworkingTypes.CommandRuntime = Commands
		TestUtils.ready(fixture)
		local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
		local domain: PublicTypes.DomainView? = view:GetDomain("Game.Actions")
		assert(domain ~= nil, "Existing Actor domain must remain installed")
		local requestId: number?, reason: string? = runtime.Send("Game.Ping")
		expect(reason).toBeNil()
		expect(type(requestId)).toBe("number")

		TestUtils.records(fixture, {
			{
				kind = "Commit",
				handle = 7,
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

		expect(Registry.GetActorViewById(view:GetId())).toBe(view)
		expect(domain:GetState()).toEqual({ active = true, mode = "Idle" })
		expect(fixture.client.order[1]).toBe("Listen")
		expect(fixture.client.disconnectCalls).toBe(0)
		expect(#fixture.sent).toBe(1)
	end
)

for _, failure: string in { "ReadyRejected", "HandshakeTimeout", "ClientReset" } do
	it("leaves the command facade inert and disconnects the installed consumers on " .. failure, function()
		local runtime: NetworkingTypes.CommandRuntime = Commands
		TestUtils.start(fixture)
		TestUtils.bootstrap(fixture)

		if failure == "ReadyRejected" then
			ClientUtils.emit(fixture.client, ProtocolUtils.encode({ kind = "Reject", reason = "ReadyRejected" }))
		elseif failure == "HandshakeTimeout" then
			assert(fixture.client.timeoutCallback ~= nil, "Expected startup timeout")
			fixture.client.timeoutCallback()
		else
			Client._ResetForTests()
		end

		ClientUtils.expectFailure(fixture.client, failure)
		expectNotAdmitted(runtime)
		Client._ResetForTests()
		expect(fixture.client.disconnectCalls).toBe(1)
		expect(fixture.client.listening).toBe(false)
	end)
end

it("stops command admission and Actor reception after repeated successful-client teardown", function()
	local runtime: NetworkingTypes.CommandRuntime = Commands
	TestUtils.ready(fixture)
	TestUtils.baseline(fixture)
	Client._ResetForTests()
	Client._ResetForTests()
	expectNotAdmitted(runtime)
	expect(fixture.client.disconnectCalls).toBe(1)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	expect(Registry.GetAllActorViews()).toEqual({})
end)

it("exposes only Send and read-only runtime events, without transport or private ownership", function()
	local runtime: NetworkingTypes.CommandRuntime = Commands
	TestUtils.ready(fixture)
	local keys: { string } = {}

	for key: string in runtime :: any do
		table.insert(keys, key)
	end

	table.sort(keys)
	expect(keys).toEqual({ "OnCommandResult", "OnCommandUncertain", "Send" })
	expect(table.isfrozen(runtime)).toBe(true)

	for _, event: any in { runtime.OnCommandResult, runtime.OnCommandUncertain } do
		expectReadOnlyEvent(event)
	end
end)
