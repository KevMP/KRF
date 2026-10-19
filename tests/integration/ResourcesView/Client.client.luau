--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Client = require(KRF.client)
local Registry: Types.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local ProtocolCodec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local ActorCodec = require(KRF.shared.Networking.ActorStreamCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Transport = require(KRF.shared.Networking.Transport)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ResourcesViewTestControl") :: RemoteEvent
local root: Folder = ReplicatedStorage:WaitForChild(Transport.ROOT_NAME) :: Folder
local reliable: RemoteEvent = root:WaitForChild(Transport.RELIABLE_NAME) :: RemoteEvent

local codec: SharedTypes.ActorStreamCodec? = nil
local actorPackets: number = 0
local baselineEnds: number = 0
local view: Types.ActorView? = nil
local resources: Types.ResourcesView? = nil
local domain: Types.DomainView? = nil
local stale: Types.ResourcesView? = nil
local staminaAnchor: any = nil
local changes: { Types.ResourceViewChange } = {}
local connection: SignalTypes.Connection? = nil
local failed: boolean = false

local function report(phase: string, failure: string?): ()
	control:FireServer(buffer.fromstring(HttpService:JSONEncode({ phase = phase, failure = failure })))
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 22

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.02)
	end
end

-- Listen to the actual endpoint. Client.Init below installs the real consumer;
-- this observer neither substitutes for it nor injects decoded messages.
local endpointConnection: RBXScriptConnection = reliable.OnClientEvent:Connect(function(payload: any)
	if failed then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Framework transport must carry buffers")
		assert(not string.find(buffer.tostring(payload), "Private.Secret", 1, true), "Private id leaked on the wire")

		assert(
			not string.find(buffer.tostring(payload), "Private.Live", 1, true),
			"Private assignment leaked on the wire"
		)

		if buffer.readu8(payload, 0) == Constants.PACKET_KIND then
			actorPackets += 1
			assert(codec ~= nil, "Actor traffic arrived before bootstrap")
			local records: { SharedTypes.ActorStreamRecord }?, decodeReason: string? = codec.Decode(payload)
			assert(records ~= nil, decodeReason)

			for _, record: SharedTypes.ActorStreamRecord in records do
				if record.kind == "BaselineEnd" then
					baselineEnds += 1
				end
			end
		else
			local message: SharedTypes.ProtocolMessage?, decodeReason: string? = ProtocolCodec.Decode(payload)
			assert(message ~= nil, decodeReason)

			if message.kind == "Bootstrap" then
				assert(#message.manifest.domains == 1, "Expected generated Resources domain alone")
				local definition: SharedTypes.ManifestDomain = message.manifest.domains[1]

				assert(
					definition.id == "KRF.Resources" and definition.state.kind == "Map",
					"Missing ordinary Resources Map"
				)

				assert(definition.state.key.kind == "Enum", "Missing visible Resource-id Enum")
				local ids: { string } = definition.state.key.values

				assert(
					#ids == 3
						and ids[1] == "Resource.Mana"
						and ids[2] == "Resource.Rage"
						and ids[3] == "Resource.Stamina",
					"Visible Resource codebook differs"
				)

				assert(#definition.events == 0, "Resources must remain state-only")

				local protocol: SharedTypes.ClientProtocol?, compileReason: string? =
					Manifest.Reconstruct(message.manifest)

				assert(protocol ~= nil, compileReason)

				local schema: SharedTypes.CompiledSchema?, schemaReason: string? =
					SchemaCompiler.Compile(definition.state)

				assert(schema ~= nil, schemaReason)
				codec = ActorCodec.Compile(protocol, { ["KRF.Resources"] = schema })
			end
		end
	end)

	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end)

local function checkPrivacy(): ()
	assert(domain ~= nil and resources ~= nil, "Expected native Resource views")

	for _, id: string in { "Private.Secret", "Private.Live" } do
		assert(domain:GetState()[id] == nil, "Generic DomainView leaked private Resource state")

		assert(
			not resources:HasResource(id) and resources:GetResource(id) == nil,
			"Typed ResourcesView leaked private state"
		)
	end

	assert(#root:GetChildren() == 2, "Resources introduced a separate framework transport")
end

local function runPhase(message: any): ()
	local phase: string = message.phase
	local actorId: string = message.actorId

	if phase == "Initial" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Normal Client.Init did not install ActorView consumers")

		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected initial ActorView")
		resources = view:GetResources()
		domain = view:GetDomain("KRF.Resources")
		assert(domain ~= nil, "Initial baseline omitted Resources domain")
		assert(resources:HasResource("Resource.Mana"), "ResourcesView did not wrap native baseline truth")
		assert(not resources:HasResource("Resource.Rage"), "Registered-only Resource appeared assigned")
		staminaAnchor = domain:GetState()["Resource.Stamina"]
		assert(staminaAnchor ~= nil and math.isfinite(staminaAnchor.anchorTime), "Missing finite baseline anchor")
		local beforeTime: number = workspace:GetServerTimeNow()
		local snapshot: Types.ResourceSnapshot? = resources:GetResource("Resource.Mana")
		local afterTime: number = workspace:GetServerTimeNow()
		local anchor: any = domain:GetState()["Resource.Mana"]
		assert(snapshot ~= nil and table.isfrozen(snapshot), "Missing immutable point-in-time Resource snapshot")

		assert(
			(snapshot :: any).anchorTime == nil and (snapshot :: any).anchorValue == nil,
			"Typed snapshot exposes wire fields"
		)

		assert(
			snapshot.current >= math.clamp(anchor.anchorValue + 10 * (beforeTime - anchor.anchorTime), 0, 1000) - 0.0001
				and snapshot.current
					<= math.clamp(anchor.anchorValue + 10 * (afterTime - anchor.anchorTime), 0, 1000) + 0.0001,
			"Client estimate does not use synchronized server time"
		)

		connection = resources.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
			assert(
				change.resourceId ~= "Private.Secret" and change.resourceId ~= "Private.Live",
				"Private typed change leaked"
			)

			table.insert(changes, change)
		end)

		waitFor(function(): boolean
			return baselineEnds == 1
		end, "Expected initial baseline completion")

		local packetsBefore: number = actorPackets
		local currentBefore: number = resources:GetCurrent("Resource.Mana") :: number
		task.wait(1.2)

		assert(
			(resources:GetCurrent("Resource.Mana") :: number) > currentBefore + 5,
			"Client display did not advance between anchors"
		)

		assert(actorPackets == packetsBefore, "Automatic regeneration emitted recurring Actor traffic")
		assert(#changes == 0, "Passage of time fabricated typed Resource changes")
		checkPrivacy()
	elseif phase == "Live" then
		assert(view ~= nil and domain ~= nil and resources ~= nil, "Expected live native facade")
		local currentDomain: Types.DomainView = domain

		waitFor(function(): boolean
			return currentDomain:GetState()["Resource.Mana"].anchorValue == 80
				and currentDomain:GetState()["Resource.Rage"] ~= nil
				and #changes == 2
		end, "Meaningful batch did not publish two resulting Resource entries")

		assert(view:GetResources() == resources, "Live commit replaced ResourcesView")
		assert(domain:GetState()["Resource.Stamina"] == staminaAnchor, "Unrelated Resource anchor changed")

		assert(
			changes[1].resourceId == "Resource.Mana" and changes[2].resourceId == "Resource.Rage",
			"Typed change order differs"
		)

		assert(changes[1].source == "Commit" and changes[2].source == "Commit", "Wrong live change source")
		assert(resources:GetCurrent("Resource.Rage") == 30, "Non-regenerating assigned Resource differs")
		checkPrivacy()
	elseif phase == "Rate" then
		assert(domain ~= nil and resources ~= nil, "Expected live Resource truth")
		local currentDomain: Types.DomainView = domain

		waitFor(function(): boolean
			return currentDomain:GetState()["Resource.Mana"].regenRate == 20 and #changes == 3
		end, "Rate-only Property change did not reanchor")

		assert(
			resources:GetRegenRate("Resource.Mana") == 20 and changes[3].source == "Commit",
			"Typed resolved rate differs"
		)

		checkPrivacy()
	elseif phase == "Replacement" then
		assert(view ~= nil and resources ~= nil, "Expected original facade")

		waitFor(function(): boolean
			return baselineEnds >= 2
		end, "Normal replacement baseline did not arrive")

		assert(
			Registry.GetActorViewById(actorId) == view and view:GetResources() == resources,
			"Replacement changed facade identity"
		)

		assert(#changes == 3, "Unchanged replacement fabricated change history")
	elseif phase == "AfterRecovery" then
		assert(domain ~= nil and resources ~= nil, "Expected recovered facade")
		local currentDomain: Types.DomainView = domain

		waitFor(function(): boolean
			return currentDomain:GetState()["Resource.Mana"].anchorValue == 35 and #changes == 4
		end, "Original subscriptions did not survive replacement")

		assert(changes[4].source == "Commit", "Recovery replayed history instead of live truth")
	elseif phase == "Removed" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) == nil
		end, "Actor removal did not retire views")

		assert(resources ~= nil and #resources:GetAssignedResources() == 0, "Removal retained Resource state")

		local connected: boolean = pcall(function()
			(resources :: Types.ResourcesView).OnResourceChanged:Connect(function() end)
		end)

		assert(not connected, "Removed ResourcesView still accepts subscriptions")
		stale = resources
	elseif phase == "Respawn" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Respawn did not publish a fresh ActorView")

		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected respawn ActorView")
		resources = view:GetResources()
		domain = view:GetDomain("KRF.Resources")
		assert(resources ~= stale and resources:HasResource("Resource.Mana"), "Respawn revived stale Resource state")

		assert(
			stale ~= nil and #stale:GetAssignedResources() == 0 and #changes == 4,
			"Retired subscriptions rebound to respawn"
		)

		checkPrivacy()
	elseif phase == "Reset" then
		Client._ResetForTests()
		Client._ResetForTests()

		assert(
			#Registry.GetAllActorViews() == 0 and resources ~= nil and #resources:GetAssignedResources() == 0,
			"Reset retained typed Resource state"
		)

		if connection ~= nil then
			connection:Disconnect()
		end

		endpointConnection:Disconnect()
	else
		error("Unexpected native Resources phase: " .. phase, 0)
	end

	report(phase, nil)
end

control.OnClientEvent:Connect(function(payload: any)
	if failed then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Expected native phase buffer")
		runPhase(HttpService:JSONDecode(buffer.tostring(payload)))
	end)

	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end)

local initialized: boolean, failure: Client.StartupFailure? = Client.Init()

if initialized then
	report("Ready", nil)
else
	report("Ready", if failure ~= nil then failure.reason else "Native Client.Init failed")
end
