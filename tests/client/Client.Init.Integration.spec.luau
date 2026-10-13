--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Client: ClientTypes.Client = require(KRF.client)
local Handshake: ServerNetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local ClientTestUtils = require(script.Parent.Utils.ClientTestUtils)
local ServerTestUtils = require(script.Parent.Parent.server.Utils.Networking.ServerProtocolTestUtils)
local DomainTestUtils = require(script.Parent.Parent.server.Utils.Replication.ReplicationDomainTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local CodecTestUtils = require(script.Parent.Parent.shared.Utils.Networking.CodecTestUtils)

-- Dynamic loading gives each simulated client its own module cache and
-- one-attempt state while sharing the actual protocol modules.
local requireClient: (ModuleScript) -> ClientTypes.Client = require :: any

local players: { Player } = {}
local clones: { ModuleScript } = {}
local clients: { ClientTypes.Client } = {}
local initThreads: { thread } = {}
local runtime: ServerNetworkingTypes.ServerHandshake? = nil

beforeEach(function()
	Client._ResetForTests()
	Domains._resetForTests()
end)
afterEach(function()
	for _, initThread: thread in initThreads do
		if coroutine.status(initThread) ~= "dead" then
			coroutine.close(initThread)
		end
	end
	initThreads = {}
	Client._ResetForTests()
	for _, client: ClientTypes.Client in clients do
		client._ResetForTests()
	end
	clients = {}
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
	for _, player: Player in players do
		player:Destroy()
	end
	players = {}
	for _, clone: ModuleScript in clones do
		clone:Destroy()
	end
	clones = {}
	Domains._resetForTests()
end)

it("completes Client.Init through the real server handshake without sending Actor traffic", function()
	local callbackCalls: number = 0
	local domain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.State")
	domain.snapshot = function(): any
		callbackCalls += 1
		return { active = false }
	end
	domain.observe = function(): (() -> ())?
		callbackCalls += 1
		return nil
	end
	local protocol: ProtocolTypes.PreparedProtocol = ServerTestUtils.prepare({ domain })
	local player: Player = ProtocolTestUtils.createPlayer()
	table.insert(players, player)
	local fixture: ClientTestUtils.Fixture = ClientTestUtils.new()
	local sentKinds: { string } = {}
	local deliveries: { buffer } = {}
	runtime = Handshake.new(protocol, {
		SendReliable = function(recipient: Player, payload: buffer): ()
			expect(recipient).toBe(player)
			table.insert(sentKinds, ProtocolTestUtils.decode(payload).kind)
			table.insert(deliveries, payload)
		end,
	})
	fixture.transport.SendReliable = function(payload: buffer): ()
		expect(fixture.listening).toBe(true)
		assert(runtime ~= nil, "Expected server")
		runtime:Handle(player, payload)
	end
	ClientTestUtils.start(fixture)
	if fixture.initThread ~= nil then
		table.insert(initThreads, fixture.initThread)
	end
	expect(fixture.result).toBeNil()
	-- Deliver only after the non-yielding server send callback has returned,
	-- matching Roblox's separate server/client execution contexts.
	ClientTestUtils.emit(fixture, deliveries[1])
	expect(fixture.result).toBeNil()
	ClientTestUtils.emit(fixture, deliveries[2])
	expect(fixture.result).toEqual({ success = true })
	expect(Client._IsInitialized()).toBe(true)
	assert(runtime ~= nil, "Expected server")
	expect(runtime:IsClientReady(player)).toBe(true)
	expect(sentKinds).toEqual({ "Bootstrap", "ReadyAck" })
	expect(callbackCalls).toBe(0)
end)

it("boots two isolated client modules with the same server codebook and reusable manifest buffer", function()
	local protocol: ProtocolTypes.PreparedProtocol =
		ServerTestUtils.prepare({ DomainTestUtils.createDomain("Game.State") })
	local fixtures: { [Player]: ClientTestUtils.Fixture } = {}
	local deliveries: { [Player]: { buffer } } = {}
	local installed: { ProtocolTypes.ClientProtocol } = {}
	local bootstrapBuffers: { buffer } = {}
	runtime = Handshake.new(protocol, {
		SendReliable = function(player: Player, payload: buffer): ()
			if ProtocolTestUtils.decode(payload).kind == "Bootstrap" then
				table.insert(bootstrapBuffers, payload)
			end
			table.insert(deliveries[player], payload)
		end,
	})
	for _ = 1, 2 do
		local module: ModuleScript = KRF.client:Clone()
		module.Name = "_N2ClientTest"
		module.Parent = KRF
		table.insert(clones, module)
		local client: ClientTypes.Client = requireClient(module)
		table.insert(clients, client)
		local player: Player = ProtocolTestUtils.createPlayer()
		table.insert(players, player)
		local fixture: ClientTestUtils.Fixture = ClientTestUtils.new()
		fixtures[player] = fixture
		deliveries[player] = {}
		fixture.transport.SendReliable = function(payload: buffer): ()
			assert(runtime ~= nil, "Expected server")
			runtime:Handle(player, payload)
		end
		fixture.dependencies.InstallConsumers = function(
			clientProtocol: ProtocolTypes.ClientProtocol
		): (boolean, string?, (() -> ())?)
			table.insert(installed, clientProtocol)
			return true, nil, nil
		end
		client._SetDependenciesForTests(fixture.dependencies)
		local result: ClientTestUtils.InitResult? = nil
		local initThread: thread = coroutine.create(function()
			local success: boolean, failure: ClientTypes.StartupFailure? = client.Init()
			result = { success = success, failure = failure }
		end)
		table.insert(initThreads, initThread)
		local completed: boolean = coroutine.resume(initThread)
		expect(completed).toBe(true)
		expect(result).toBeNil()
		ClientTestUtils.emit(fixtures[player], deliveries[player][1])
		expect(result).toBeNil()
		ClientTestUtils.emit(fixtures[player], deliveries[player][2])
		expect(result).toEqual({ success = true })
		assert(runtime ~= nil, "Expected server")
		expect(runtime:IsClientReady(player)).toBe(true)
	end
	expect(#bootstrapBuffers).toBe(2)
	expect(bootstrapBuffers[1]).toBe(protocol.bootstrapBuffer)
	expect(bootstrapBuffers[2]).toBe(protocol.bootstrapBuffer)
	expect(installed[1].domainsById["Game.State"].code).toBe(installed[2].domainsById["Game.State"].code)
	local encoded: buffer =
		CodecTestUtils.encode(protocol.runtime.domainsById["Game.State"].stateCodec, { active = false })
	for _, clientProtocol: ProtocolTypes.ClientProtocol in installed do
		local value: any, offset: number?, reason: string? =
			clientProtocol.domainsById["Game.State"].stateCodec.Read(encoded, 0, buffer.len(encoded))
		expect(value).toEqual({ active = false })
		expect(offset).toBe(buffer.len(encoded))
		expect(reason).toBeNil()
	end
end)
