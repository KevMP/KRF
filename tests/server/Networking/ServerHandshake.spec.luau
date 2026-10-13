--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Handshake: NetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Compiler: SharedNetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

type SentMessage = { player: Player, payload: buffer }
local players: { Player } = {}
local sent: { SentMessage } = {}
local runtime: NetworkingTypes.ServerHandshake? = nil
local protocol: ProtocolTypes.PreparedProtocol
local originalCompile: typeof(Compiler.Compile) = Compiler.Compile

beforeEach(function()
	Domains._resetForTests()
	players = { ProtocolTestUtils.createPlayer(), ProtocolTestUtils.createPlayer() }
	sent = {}
	protocol = TestUtils.prepare({ DomainTestUtils.createDomain("Game.State") })
	runtime = Handshake.new(protocol, {
		SendReliable = function(player: Player, payload: buffer): ()
			table.insert(sent, { player = player, payload = payload })
		end,
	})
end)

afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
	Compiler.Compile = originalCompile
	for _, player: Player in players do
		player:Destroy()
	end
	Domains._resetForTests()
end)

local function getRuntime(): NetworkingTypes.ServerHandshake
	assert(runtime ~= nil, "Expected handshake runtime")
	return runtime
end

local function hello(player: Player): ()
	getRuntime():Handle(player, ProtocolTestUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
end

local function ready(player: Player): ()
	getRuntime():Handle(player, ProtocolTestUtils.encode({ kind = "Ready" }))
end

it("sends the prepared bootstrap for a compatible HELLO without making the connection ready", function()
	hello(players[1])
	expect(#sent).toBe(1)
	expect(sent[1].player).toBe(players[1])
	expect(sent[1].payload).toBe(protocol.bootstrapBuffer)
	expect(ProtocolTestUtils.decode(sent[1].payload).kind).toBe("Bootstrap")
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
end)

for _, repeatCount: number in { 1, 1000 } do
	it(
		"ignores " .. tostring(repeatCount) .. " repeated HELLO packets while AwaitReady without amplifying traffic",
		function()
			local readyCalls: number = 0
			getRuntime():ObserveClientReady(function(): ()
				readyCalls += 1
			end)
			hello(players[1])
			expect(#sent).toBe(1)
			expect(sent[1].payload).toBe(protocol.bootstrapBuffer)
			local connectionCount: number = getRuntime():_GetConnectionCountForTests()
			local compileCalls: number = 0
			Compiler.Compile = function(
				schema: SharedNetworkingTypes.CompiledSchema
			): (SharedNetworkingTypes.CompiledCodec?, string?)
				compileCalls += 1
				return originalCompile(schema)
			end
			for _ = 1, repeatCount do
				hello(players[1])
			end
			expect(#sent).toBe(1)
			expect(getRuntime():_GetConnectionCountForTests()).toBe(connectionCount)
			expect(getRuntime():IsClientReady(players[1])).toBe(false)
			expect(readyCalls).toBe(0)
			expect(compileCalls).toBe(0)
			ready(players[1])
			expect(getRuntime():IsClientReady(players[1])).toBe(true)
			expect(readyCalls).toBe(1)
			expect(#sent).toBe(2)
			expect(ProtocolTestUtils.decode(sent[2].payload).kind).toBe("ReadyAck")
		end
	)
end

it("rejects an incompatible version and never accepts a subsequent READY", function()
	getRuntime():Handle(
		players[1],
		ProtocolTestUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION + 1 })
	)
	ready(players[1])
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	for _, message: SentMessage in sent do
		expect(ProtocolTestUtils.decode(message.payload).kind == "Bootstrap").toBe(false)
	end
end)

it("rejects READY before HELLO without creating partial readiness", function()
	ready(players[1])
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	for _, message: SentMessage in sent do
		expect(ProtocolTestUtils.decode(message.payload).kind == "ReadyAck").toBe(false)
	end
end)

it("marks ready before sending READY_ACK and fires Ready observers exactly once afterward", function()
	local order: { string } = {}
	local readyCalls: number = 0
	local publication: buffer = buffer.fromstring("future publication")
	getRuntime():Destroy()
	runtime = Handshake.new(protocol, {
		SendReliable = function(player: Player, payload: buffer): ()
			if payload == publication then
				table.insert(order, "Publication")
				return
			end
			local message: ProtocolTypes.Message = ProtocolTestUtils.decode(payload)
			if message.kind == "ReadyAck" then
				expect(getRuntime():IsClientReady(player)).toBe(true)
			end
			table.insert(order, message.kind)
		end,
	})
	getRuntime():ObserveClientReady(function(player: Player): ()
		readyCalls += 1
		expect(player).toBe(players[1])
		expect(getRuntime():IsClientReady(player)).toBe(true)
		table.insert(order, "ReadyObserver")
		local sentPublication: boolean, reason: string? = getRuntime():Send(player, publication)
		expect(sentPublication).toBe(true)
		expect(reason).toBeNil()
	end)
	local disconnect: () -> () = getRuntime():ObserveClientReady(function(): () end)
	disconnect()
	hello(players[1])
	ready(players[1])
	ready(players[1])
	expect(readyCalls).toBe(1)
	expect(order[1]).toBe("Bootstrap")
	expect(order[2]).toBe("ReadyAck")
	expect(order[3]).toBe("ReadyObserver")
	expect(order[4]).toBe("Publication")
end)

it("gates later reliable publication independently for each connection", function()
	local publication: buffer = buffer.fromstring("opaque later-story record")
	local sentBefore: boolean, beforeReason: string? = getRuntime():Send(players[1], publication)
	expect(sentBefore).toBe(false)
	expect(beforeReason).toBe("ClientNotReady")
	hello(players[1])
	hello(players[2])
	ready(players[1])
	local sentReady: boolean, readyReason: string? = getRuntime():Send(players[1], publication)
	local sentWaiting: boolean, waitingReason: string? = getRuntime():Send(players[2], publication)
	expect(sentReady).toBe(true)
	expect(readyReason).toBeNil()
	expect(sentWaiting).toBe(false)
	expect(waitingReason).toBe("ClientNotReady")
	expect(sent[#sent].payload).toBe(publication)
	expect(sent[#sent].player).toBe(players[1])
end)

it("does not restart bootstrap or emit duplicate acknowledgements after readiness", function()
	hello(players[1])
	ready(players[1])
	local sentCount: number = #sent
	hello(players[1])
	ready(players[1])
	expect(#sent).toBe(sentCount)
	expect(getRuntime():IsClientReady(players[1])).toBe(true)
end)

it("reuses one global bootstrap across two clients without recompiling codecs", function()
	local compileCalls: number = 0
	Compiler.Compile = function(
		schema: SharedNetworkingTypes.CompiledSchema
	): (SharedNetworkingTypes.CompiledCodec?, string?)
		compileCalls += 1
		return originalCompile(schema)
	end
	hello(players[1])
	hello(players[2])
	expect(sent[1].payload).toBe(protocol.bootstrapBuffer)
	expect(sent[2].payload).toBe(protocol.bootstrapBuffer)
	ready(players[1])
	ready(players[2])
	expect(getRuntime():IsClientReady(players[1])).toBe(true)
	expect(getRuntime():IsClientReady(players[2])).toBe(true)
	expect(compileCalls).toBe(0)
	expect(#sent).toBe(4)
end)

it("rejects repeated malformed, non-buffer and unknown traffic without throwing or accumulating state", function()
	local initialCount: number = getRuntime():_GetConnectionCountForTests()
	local unknown: buffer = buffer.create(1)
	buffer.writeu8(unknown, 0, 255)
	local completed: boolean = pcall(function()
		for _ = 1, 1000 do
			for _, payload: any in { {}, false, "HELLO", buffer.create(0), unknown } do
				getRuntime():Handle(players[1], payload)
			end
		end
	end)
	expect(completed).toBe(true)
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	expect(getRuntime():_GetConnectionCountForTests() <= initialCount + 1).toBe(true)
end)

it("rejects additional RemoteEvent arguments instead of accepting positional handshake data", function()
	getRuntime():Handle(
		players[1],
		ProtocolTestUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }),
		{ extra = true }
	)
	ready(players[1])
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	for _, message: SentMessage in sent do
		expect(ProtocolTestUtils.decode(message.payload).kind == "Bootstrap").toBe(false)
	end
end)

it("cleans waiting and ready connections and fires Closed exactly once per teardown", function()
	local closed: { Player } = {}
	getRuntime():ObserveClientClosed(function(player: Player): ()
		table.insert(closed, player)
	end)
	hello(players[1])
	hello(players[2])
	ready(players[1])
	getRuntime():Close(players[1])
	getRuntime():Close(players[1])
	getRuntime():Close(players[2])
	expect(closed).toEqual({ players[1], players[2] })
	expect(getRuntime():_GetConnectionCountForTests()).toBe(0)
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	local sentAfterClose: boolean, reason: string? = getRuntime():Send(players[1], buffer.create(0))
	expect(sentAfterClose).toBe(false)
	expect(reason).toBe("ClientNotReady")
end)

it("supports idempotent observer unsubscribe and runtime destruction", function()
	local readyCalls: number = 0
	local closedCalls: number = 0
	local unsubscribeReady: () -> () = getRuntime():ObserveClientReady(function(): ()
		readyCalls += 1
	end)
	local unsubscribeClosed: () -> () = getRuntime():ObserveClientClosed(function(): ()
		closedCalls += 1
	end)
	unsubscribeReady()
	unsubscribeReady()
	unsubscribeClosed()
	unsubscribeClosed()
	hello(players[1])
	ready(players[1])
	getRuntime():Close(players[1])
	getRuntime():Destroy()
	getRuntime():Destroy()
	expect(readyCalls).toBe(0)
	expect(closedCalls).toBe(0)
	expect(getRuntime():_GetConnectionCountForTests()).toBe(0)
end)

it("runs both valid handshake callbacks to completion without yielding", function()
	local messages: { ProtocolTypes.Message } =
		{ { kind = "Hello", version = Constants.PROTOCOL_VERSION }, { kind = "Ready" } }
	for _, message: ProtocolTypes.Message in messages do
		local thread: thread = coroutine.create(function()
			getRuntime():Handle(players[1], ProtocolTestUtils.encode(message))
		end)
		local completed: boolean = coroutine.resume(thread)
		expect(completed).toBe(true)
		expect(coroutine.status(thread)).toBe("dead")
	end
end)

it("does not accept READY when bootstrap transmission failed", function()
	getRuntime():Destroy()
	runtime = Handshake.new(protocol, {
		SendReliable = function(_player: Player, payload: buffer): ()
			if ProtocolTestUtils.decode(payload).kind == "Bootstrap" then
				error("BootstrapSendFailure")
			end
		end,
	})
	-- An unexpected engine send failure may be surfaced or reported internally;
	-- either way the connection must not advance to AwaitReady.
	local _completed: boolean = pcall(function()
		hello(players[1])
	end)
	ready(players[1])
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
end)

it("rejects server-originated message kinds on the client-to-server lane", function()
	local messages: { ProtocolTypes.Message } = {
		{ kind = "Bootstrap", manifest = protocol.manifest },
		{ kind = "ReadyAck" },
		{ kind = "Reject", reason = "ReadyRejected" },
	}
	for _, message: ProtocolTypes.Message in messages do
		getRuntime():Handle(players[1], ProtocolTestUtils.encode(message))
	end
	ready(players[1])
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
	for _, message: SentMessage in sent do
		expect(ProtocolTestUtils.decode(message.payload).kind == "ReadyAck").toBe(false)
	end
end)

it("destroys pending and ready connections with exactly one Closed notification each", function()
	local closed: { [Player]: number } = {}
	getRuntime():ObserveClientClosed(function(player: Player): ()
		closed[player] = (closed[player] or 0) + 1
	end)
	hello(players[1])
	hello(players[2])
	ready(players[1])
	getRuntime():Destroy()
	getRuntime():Destroy()
	expect(closed[players[1]]).toBe(1)
	expect(closed[players[2]]).toBe(1)
	expect(getRuntime():_GetConnectionCountForTests()).toBe(0)
	expect(getRuntime():IsClientReady(players[1])).toBe(false)
end)
