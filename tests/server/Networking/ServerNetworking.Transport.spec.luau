--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Handshake: NetworkingTypes.ServerHandshakeModule = require(KRF.server.Networking.ServerHandshake)
local Transport: ProtocolTypes.Transport = require(KRF.shared.Networking.Transport)
local Codec: ProtocolTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Compiler: SharedTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)
local DomainTestUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local ServerTestUtils = require(script.Parent.Parent.Utils.Networking.ServerProtocolTestUtils)
local ProtocolTestUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

local originalCreate: typeof(Transport.Create) = Transport.Create
local originalNew: typeof(Handshake.new) = Handshake.new
local originalEncode: typeof(Codec.Encode) = Codec.Encode
local originalCompile: typeof(Compiler.Compile) = Compiler.Compile
local inbound: BindableEvent
local barrier: BindableEvent
local root: Folder
local sent: { buffer } = {}
local player: Player
local protocol: ProtocolTypes.PreparedProtocol

beforeEach(function()
	Networking.Destroy()
	Domains._resetForTests()
	protocol = ServerTestUtils.prepare({ DomainTestUtils.createDomain("Game.State") })
	inbound = Instance.new("BindableEvent")
	barrier = Instance.new("BindableEvent")
	root = Instance.new("Folder")
	sent = {}
	-- BindableEvent preserves Instance identity, while arbitrary tables are
	-- copied. Use a capability-safe Instance as the injected connected player.
	player = ProtocolTestUtils.createPlayer()
	player.Parent = Players
	Transport.Create = function(parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
		root.Parent = parent
		local reliable: any = {
			OnServerEvent = inbound.Event,
			FireClient = function(_self: any, recipient: Player, payload: buffer): ()
				expect(recipient).toBe(player)
				table.insert(sent, payload)
			end,
		}
		return {
			root = root,
			reliable = reliable,
			unreliable = {} :: any,
			Destroy = function(): ()
				root:Destroy()
			end,
		},
			nil
	end
end)

afterEach(function()
	Networking.Destroy()
	Domains._resetForTests()
	Transport.Create = originalCreate
	Handshake.new = originalNew
	Codec.Encode = originalEncode
	Compiler.Compile = originalCompile
	inbound:Destroy()
	barrier:Destroy()
	root:Destroy()
	player:Destroy()
end)

local function emit(message: ProtocolTypes.Message): ()
	inbound:Fire(player, ProtocolTestUtils.encode(message))
	task.defer(function(): ()
		barrier:Fire()
	end)
	barrier.Event:Wait()
end

it("wires the reliable listener to the handshake and exposes private ready/closed seams after activation", function()
	local success: boolean, failure: string? = Networking.Publish(protocol)
	expect(success).toBe(true)
	expect(failure).toBeNil()
	local readyCalls: number = 0
	local closedCalls: number = 0
	Networking.ObserveClientReady(function(recipient: Player): ()
		expect(recipient).toBe(player)
		readyCalls += 1
	end)
	Networking.ObserveClientClosed(function(recipient: Player): ()
		expect(recipient).toBe(player)
		closedCalls += 1
	end)
	expect(Networking.IsClientReady(player)).toBe(false)
	local sentBefore: boolean, beforeReason: string? = Networking.SendReliable(player, buffer.create(0))
	expect(sentBefore).toBe(false)
	expect(beforeReason).toBe("ClientNotReady")
	emit({ kind = "Hello", version = Constants.PROTOCOL_VERSION })
	expect(sent[1]).toBe(protocol.bootstrapBuffer)
	emit({ kind = "Ready" })
	expect(Networking.IsClientReady(player)).toBe(true)
	expect(ProtocolTestUtils.decode(sent[2]).kind).toBe("ReadyAck")
	expect(readyCalls).toBe(1)
	local publication: buffer = buffer.fromstring("future record")
	local sentAfter: boolean, afterReason: string? = Networking.SendReliable(player, publication)
	expect(sentAfter).toBe(true)
	expect(afterReason).toBeNil()
	expect(sent[3]).toBe(publication)
	Networking.Destroy()
	Networking.Destroy()
	expect(closedCalls).toBe(1)
	expect(Networking.IsClientReady(player)).toBe(false)
	expect(root.Parent).toBeNil()
	emit({ kind = "Hello", version = Constants.PROTOCOL_VERSION })
	expect(#sent).toBe(3)
end)

it("ignores queued reliable messages from a Player that has left Players", function()
	local success: boolean, failure: string? = Networking.Publish(protocol)
	expect(success).toBe(true)
	expect(failure).toBeNil()
	player.Parent = nil
	emit({ kind = "Hello", version = Constants.PROTOCOL_VERSION })
	expect(sent).toEqual({})
	expect(Networking.IsClientReady(player)).toBe(false)
end)

it("rejects duplicate activation without replacing the live transports", function()
	local first: boolean, firstReason: string? = Networking.Publish(protocol)
	local second: boolean, secondReason: string? = Networking.Publish(protocol)
	expect(first).toBe(true)
	expect(firstReason).toBeNil()
	expect(second).toBe(false)
	expect(secondReason).toBe("NetworkingAlreadyInitialized")
	expect(root.Parent).toBe(ReplicatedStorage)
end)

it("returns transport creation failure without publishing a runtime", function()
	Transport.Create = function(_parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
		return nil, "TransportConflict"
	end
	local success: boolean, failure: string? = Networking.Publish(protocol)
	expect(success).toBe(false)
	expect(failure).toBe("TransportConflict")
	expect(Networking._IsInitialized()).toBe(false)
end)

it("removes only owned transports when handshake construction unexpectedly fails", function()
	Handshake.new = function(
		_protocol: ProtocolTypes.PreparedProtocol,
		_dependencies: NetworkingTypes.HandshakeDependencies
	): NetworkingTypes.ServerHandshake
		error("HandshakeConstructionFailed")
	end
	local completed: boolean, reason: any = pcall(Networking.Publish, protocol)
	expect(completed).toBe(false)
	expect(string.find(tostring(reason), "HandshakeConstructionFailed", 1, true) ~= nil).toBe(true)
	expect(root.Parent).toBeNil()
	expect(Networking._IsInitialized()).toBe(false)
end)

it("rejects private observation and publication before any runtime is activated", function()
	expect(Networking.IsClientReady(player)).toBe(false)
	local success: boolean, reason: string? = Networking.SendReliable(player, buffer.create(0))
	expect(success).toBe(false)
	expect(reason).toBe("ClientNotReady")
	expect(function()
		Networking.ObserveClientReady(function(): () end)
	end).toThrow("NetworkingNotInitialized")
	expect(function()
		Networking.ObserveClientClosed(function(): () end)
	end).toThrow("NetworkingNotInitialized")
end)

it("distinguishes a malformed encoded manifest from event codec compilation failure", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog =
		DomainTestUtils.prepare({ DomainTestUtils.createDomain("Game.Other") })
	Codec.Encode = function(_message: ProtocolTypes.Message): (buffer?, string?)
		return nil, "UnsupportedSchema"
	end
	local rejected: ProtocolTypes.PreparedProtocol?, reason: string? = Networking.Prepare(catalog)
	expect(rejected).toBeNil()
	expect(reason).toBe("InvalidProtocolManifest")
	Codec.Encode = originalEncode
	local domain: ReplicationTypes.ReplicationDomainDefinition = DomainTestUtils.createDomain("Game.Events")
	domain.events = { { id = "Changed", payload = domain.state } }
	catalog = DomainTestUtils.prepare({ domain })
	local calls: number = 0
	Compiler.Compile = function(schema: SharedTypes.CompiledSchema): (SharedTypes.CompiledCodec?, string?)
		calls += 1
		if calls == 2 then
			return nil, "UnsupportedSchema"
		end
		return originalCompile(schema)
	end
	rejected, reason = Networking.Prepare(catalog)
	expect(rejected).toBeNil()
	expect(reason).toBe("CodecCompilationFailure")
end)
