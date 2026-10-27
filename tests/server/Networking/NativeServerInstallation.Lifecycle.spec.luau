--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local SharedTypes = require(KRF.shared.Networking.types)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Installation = require(KRF.server.Networking.utils.NativeServerInstallation)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local owner: Installation.Runtime? = nil
local instances: { Instance } = {}

afterEach(function()
	if owner ~= nil then
		owner:Destroy()
	end

	owner = nil
	Networking.Destroy()

	for _, instance in instances do
		instance:Destroy()
	end

	instances = {}
end)

it("owns a transport-only session once when closed observers reenter destruction", function()
	local catalog = DomainUtils.prepare({})
	local protocol = assert(Networking.Prepare(catalog))
	local incoming = Instance.new("BindableEvent")
	local root = Instance.new("Folder")
	local player = ProtocolUtils.createPlayer()
	instances = { incoming, root, player }
	local sent: { buffer } = {}
	local destroyed = 0

	local transports: SharedTypes.OwnedTransport = {
		root = root,
		reliable = {
			OnServerEvent = incoming.Event,
			FireClient = function(_self: RemoteEvent, recipient: Player, payload: buffer): ()
				expect(recipient).toBe(player)
				table.insert(sent, payload)
			end,
		} :: any,
		unreliable = {} :: any,
		Destroy = function(): ()
			destroyed += 1
			root:Destroy()
		end,
	}

	local created: Installation.Runtime = Installation.new(transports)
	owner = created
	local admitted, reason = created:SendReliable(player, buffer.create(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	created:Start(protocol, nil, nil, nil)
	local ready, closed = 0, 0

	created:ObserveClientReady(function(): ()
		ready += 1
	end)

	created:ObserveClientClosed(function(): ()
		closed += 1
		created:Destroy()
	end)

	local handshake = assert(created.runtime, "Expected installed handshake")
	handshake:Handle(player, ProtocolUtils.encode({ kind = "Hello", version = Constants.PROTOCOL_VERSION }))
	handshake:Handle(player, ProtocolUtils.encode({ kind = "Ready" }))
	expect(ready).toBe(1)
	expect(created:IsClientReady(player)).toBe(true)
	expect(#sent).toBe(2)
	admitted, reason = created:RequestReplacementBaseline(player, 1, "NoPublication")
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	created:Destroy()
	created:Destroy()
	expect(closed).toBe(1)
	expect(destroyed).toBe(1)
	expect(created:IsClientReady(player)).toBe(false)
	admitted, reason = created:SendReliable(player, buffer.create(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
end)
