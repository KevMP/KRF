--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Handshake: NetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local ServerTestUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local runtime: NetworkingTypes.ServerHandshake
local protocol: ProtocolTypes.PreparedProtocol
local player: Player

beforeEach(function()
	Domains._resetForTests()
	protocol = ServerTestUtils.prepare({})
	player = ProtocolTestUtils.createPlayer()
	runtime = Handshake.new(protocol, { SendReliable = function(_player: Player, _payload: buffer): () end })
end)
afterEach(function()
	runtime:Destroy()
	player:Destroy()
	Domains._resetForTests()
end)

local function becomeReady(): ()
	runtime:Handle(player, ProtocolTestUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	runtime:Handle(player, ProtocolTestUtils.encode({ kind = "Ready" }))
end

for _, behavior: string in { "throws", "yields" } do
	it("isolates a private Ready observer that " .. behavior .. " without suspending handshake dispatch", function()
		local followingCalls: number = 0
		runtime:ObserveClientReady(function(): ()
			if behavior == "throws" then
				error("ObserverFailure")
			end
			coroutine.yield()
		end)
		runtime:ObserveClientReady(function(): ()
			followingCalls += 1
		end)
		local thread: thread = coroutine.create(becomeReady)
		local completed: boolean = coroutine.resume(thread)
		expect(completed).toBe(true)
		expect(coroutine.status(thread)).toBe("dead")
		expect(runtime:IsClientReady(player)).toBe(true)
		expect(followingCalls).toBe(1)
	end)
end

it("respects observer unsubscribe during dispatch and stops Ready notifications after connection closure", function()
	local skippedCalls: number = 0
	local lateCalls: number = 0
	local disconnectNext: () -> () = function(): () end
	runtime:ObserveClientReady(function(): ()
		disconnectNext()
	end)
	disconnectNext = runtime:ObserveClientReady(function(): ()
		skippedCalls += 1
	end)
	runtime:ObserveClientReady(function(): ()
		runtime:Close(player)
	end)
	runtime:ObserveClientReady(function(): ()
		lateCalls += 1
	end)
	becomeReady()
	expect(skippedCalls).toBe(0)
	expect(lateCalls).toBe(0)
	expect(runtime:IsClientReady(player)).toBe(false)
end)

it("does not notify Ready or reopen a connection when READY_ACK transmission fails", function()
	runtime:Destroy()
	runtime = Handshake.new(protocol, {
		SendReliable = function(_player: Player, payload: buffer): ()
			if ProtocolTestUtils.decode(payload).kind == "ReadyAck" then
				error("AcknowledgementFailure")
			end
		end,
	})
	local readyCalls: number = 0
	runtime:ObserveClientReady(function(): ()
		readyCalls += 1
	end)
	becomeReady()
	expect(runtime:IsClientReady(player)).toBe(false)
	expect(readyCalls).toBe(0)
	runtime:Handle(player, ProtocolTestUtils.encode({ kind = "Ready" }))
	expect(readyCalls).toBe(0)
end)

it("does not resurrect connection state when a player closes during bootstrap transmission", function()
	runtime:Destroy()
	runtime = Handshake.new(protocol, {
		SendReliable = function(recipient: Player, _payload: buffer): ()
			runtime:Close(recipient)
		end,
	})
	becomeReady()
	expect(runtime:_GetConnectionCountForTests()).toBe(0)
	expect(runtime:IsClientReady(player)).toBe(false)
	runtime:Handle(player, ProtocolTestUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	expect(runtime:_GetConnectionCountForTests()).toBe(0)
end)

it("reports failed reliable publication after readiness without throwing into its caller", function()
	becomeReady()
	runtime:Destroy()
	local failing: boolean = false
	runtime = Handshake.new(protocol, {
		SendReliable = function(_player: Player, _payload: buffer): ()
			if failing then
				error("PublicationFailure")
			end
		end,
	})
	becomeReady()
	failing = true
	local success: boolean, reason: string? = runtime:Send(player, buffer.create(0))
	expect(success).toBe(false)
	expect(reason).toBe("TransportSendFailed")
end)

it("ignores new work and treats subscriptions and unsubscribe as no-ops after destruction", function()
	local calls: number = 0
	local unsubscribe: () -> () = runtime:ObserveClientReady(function(): ()
		calls += 1
	end)
	runtime:Destroy()
	unsubscribe()
	unsubscribe()
	local unsubscribeAfter: () -> () = runtime:ObserveClientReady(function(): ()
		calls += 1
	end)
	unsubscribeAfter()
	becomeReady()
	expect(calls).toBe(0)
	expect(runtime:_GetConnectionCountForTests()).toBe(0)
end)

it("keeps duplicate callback subscriptions independent when one unsubscribes during Ready dispatch", function()
	local calls: number = 0
	local disconnectSecond: () -> () = function(): () end
	local callback: (Player) -> () = function(): ()
		calls += 1
		disconnectSecond()
	end
	runtime:ObserveClientReady(callback)
	disconnectSecond = runtime:ObserveClientReady(callback)
	becomeReady()
	expect(calls).toBe(1)
end)
