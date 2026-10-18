--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingTestControl") :: RemoteEvent
local Client = require(KRF.client)
local ClientTypes = require(KRF.client.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Transport = require(KRF.shared.Networking.Transport)
local Codec: SharedNetworkingTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)

local codebooks: { string } = {}
local order: { string } = {}
local publicationArrived: boolean = false
local publicationSignal: BindableEvent = Instance.new("BindableEvent")

Native.InstallConsumers = function(protocol: SharedNetworkingTypes.ClientProtocol): (boolean, string?, (() -> ())?)
	for id: string, domain: SharedNetworkingTypes.ClientDomain in protocol.domainsById do
		table.insert(codebooks, id .. ":" .. tostring(domain.code))

		for eventId: string, event: SharedNetworkingTypes.ClientEvent in domain.eventsById do
			table.insert(codebooks, id .. "." .. eventId .. ":" .. tostring(event.code))
		end
	end

	table.sort(codebooks)
	local owned: SharedNetworkingTypes.OwnedTransport?, reason: string? = Transport.Locate(ReplicatedStorage)
	assert(owned ~= nil, reason)

	local connection: RBXScriptConnection = owned.reliable.OnClientEvent:Connect(function(payload: any): ()
		local message: SharedNetworkingTypes.ProtocolMessage? = Codec.Decode(payload)

		if message ~= nil and message.kind == "ReadyAck" then
			table.insert(order, "ReadyAck")
		elseif typeof(payload) == "buffer" and buffer.tostring(payload) == "KRF engine ordering marker" then
			table.insert(order, "Publication")
			publicationArrived = true
			publicationSignal:Fire()
		end
	end)

	return true, nil, function(): ()
		connection:Disconnect()
		publicationSignal:Destroy()
	end
end

control.OnClientEvent:Connect(function(payload: buffer): ()
	if buffer.tostring(payload) ~= "Leave" then
		return
	end

	if StudioTestService:CanLeaveTest() then
		StudioTestService:LeaveTest()
	else
		control:FireServer(buffer.fromstring("Client cannot leave multiplayer test"))
	end
end)

local initialized: boolean, failure: Client.StartupFailure? = Client.Init()

if not initialized then
	control:FireServer(buffer.fromstring(if failure ~= nil then failure.reason else "Client initialization failed"))

	return
end

if not publicationArrived then
	publicationSignal.Event:Wait()
end

if #order ~= 2 or order[1] ~= "ReadyAck" or order[2] ~= "Publication" then
	control:FireServer(buffer.fromstring("Publication raced READY_ACK"))

	return
end

control:FireServer(buffer.fromstring("Ready|" .. table.concat(codebooks, ";")))
