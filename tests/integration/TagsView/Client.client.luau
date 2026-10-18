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
local control: RemoteEvent = ReplicatedStorage:WaitForChild("TagsViewTestControl") :: RemoteEvent

-- Normal Client.Init owns discovery, consumer installation, N4 and N5. This
-- fixture only observes the actual Reliable endpoint; no receiver is injected.
local root: Folder = ReplicatedStorage:WaitForChild(Transport.ROOT_NAME) :: Folder
local reliable: RemoteEvent = root:WaitForChild(Transport.RELIABLE_NAME) :: RemoteEvent
local codec: SharedTypes.ActorStreamCodec? = nil
local actorPackets: number = 0
local baselineEnds: number = 0
local view: Types.ActorView? = nil
local domain: Types.DomainView? = nil
local tags: Types.TagsView? = nil
local staleTags: Types.TagsView? = nil
local sources: { Types.DomainChangeSource } = {}
local semantic: { { id: string, tagId: string, stackCount: number?, timedActive: boolean } } = {}
local connections: { SignalTypes.Connection } = {}
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

local endpointConnection: RBXScriptConnection = reliable.OnClientEvent:Connect(function(payload: any)
	if failed then
		return
	end
	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Native framework transport must carry buffers")
		assert(
			not string.find(buffer.tostring(payload), "Private.Native", 1, true),
			"Private Tag id leaked on the wire"
		)
		if buffer.readu8(payload, 0) == Constants.PACKET_KIND then
			actorPackets += 1
			assert(codec ~= nil, "Actor traffic arrived before a valid bootstrap")
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
				assert(#message.manifest.domains == 1, "Expected the generated built-in domain alone")
				local definition: SharedTypes.ManifestDomain = message.manifest.domains[1]
				assert(definition.id == "KRF.Tags" and definition.state.kind == "Map", "Missing ordinary Tags Map")
				assert(definition.state.key.kind == "Enum", "Expected visible Tag-id Enum")
				assert(#definition.state.key.values == 2, "Bootstrap included hidden Tag definitions")
				assert(
					definition.state.key.values[1] == "Buff.NativeStack"
						and definition.state.key.values[2] == "Status.NativeTimed",
					"Visible codebook differs"
				)
				assert(#definition.events == 4, "Unexpected Tag semantic event vocabulary")
				local eventIds: { string } = {}
				for _, event: SharedTypes.ManifestEvent in definition.events do
					table.insert(eventIds, event.id)
					assert(
						event.payload.kind == "Enum" and #event.payload.values == 2,
						"Hidden Tag ids leaked through event schema"
					)
					assert(
						event.payload.values[1] == "Buff.NativeStack"
							and event.payload.values[2] == "Status.NativeTimed",
						"Tag event codebook differs from visible state"
					)
				end
				table.sort(eventIds)
				assert(
					table.concat(eventIds, ",") == "Added,Expired,Refreshed,Removed",
					"Native protocol added or renamed Tag lifecycle events"
				)
				local protocol: SharedTypes.ClientProtocol?, compileReason: string? =
					Manifest.Reconstruct(message.manifest)
				assert(protocol ~= nil, compileReason)
				local schema: SharedTypes.CompiledSchema?, schemaReason: string? =
					SchemaCompiler.Compile(definition.state)
				assert(schema ~= nil, schemaReason)
				codec = ActorCodec.Compile(protocol, { ["KRF.Tags"] = schema })
			end
		end
	end)
	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end)

local function checkPrivacy(): ()
	assert(view ~= nil and tags ~= nil and domain ~= nil, "Expected native views")
	assert(domain:GetState()["Private.Native"] == nil, "Generic DomainView leaked private Tag state")
	assert(
		not tags:HasTag("Private.Native") and tags:GetTag("Private.Native") == nil,
		"Typed TagsView leaked private Tag state"
	)
	for _, entry: Types.ActiveTagSnapshot in tags:GetActiveTags() do
		assert(entry.tagId ~= "Private.Native", "Private Tag appeared in typed active list")
	end
	local children: { string } = {}
	for _, child: Instance in root:GetChildren() do
		table.insert(children, child.Name .. ":" .. child.ClassName)
	end
	table.sort(children)
	assert(
		#children == 2 and children[1] == "Reliable:RemoteEvent" and children[2] == "Unreliable:UnreliableRemoteEvent",
		"Tags added a separate framework transport"
	)
end

local function runPhase(message: any): ()
	local phase: string = message.phase
	local actorId: string = message.actorId
	if phase == "Initial" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Normal Client.Init did not install ActorView consumers")
		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected native ActorView")
		tags = view:GetTags()
		domain = view:GetDomain("KRF.Tags")
		assert(domain ~= nil, "Initial native baseline omitted the built-in domain")
		assert(
			domain:GetState()["Buff.NativeStack"] ~= nil,
			"Initial baseline must contain pre-seeded visible aggregate"
		)
		assert(tags:HasTag("Status.NativeTimed"), "TagsView did not wrap native baseline truth")
		local stack: Types.ActiveTagSnapshot? = tags:GetTag("Buff.NativeStack")
		assert(stack ~= nil and stack.stackCount == 2, "Native aggregate stack count differs")
		assert(
			table.isfrozen(stack) and (stack :: any).expiresAt == nil,
			"Typed snapshot is mutable or exposes the wire anchor"
		)
		local before: number = workspace:GetServerTimeNow()
		local timed: Types.ActiveTagSnapshot? = tags:GetTag("Status.NativeTimed")
		local after: number = workspace:GetServerTimeNow()
		local expiresAt: number = domain:GetState()["Status.NativeTimed"].expiresAt
		assert(timed ~= nil and timed.remainingDuration ~= nil, "Missing derived native duration")
		assert(
			timed.remainingDuration >= math.max(0, expiresAt - after) - 0.0001
				and timed.remainingDuration <= math.max(0, expiresAt - before) + 0.0001,
			"TagsView did not use the synchronized Workspace clock"
		)
		for _, id: string in { "Added", "Refreshed", "Removed", "Expired" } do
			local event: SignalTypes.Event<string> = (tags :: any)["OnTag" .. id]
			table.insert(
				connections,
				event:Connect(function(tagId: string)
					assert(tagId ~= "Private.Native", "Private Tag semantic event leaked")
					local current: Types.TagsView = tags :: Types.TagsView
					local currentStack: Types.ActiveTagSnapshot? = current:GetTag("Buff.NativeStack")
					table.insert(semantic, {
						id = id,
						tagId = tagId,
						stackCount = if currentStack ~= nil then currentStack.stackCount else nil,
						timedActive = current:HasTag("Status.NativeTimed"),
					})
				end)
			)
		end
		table.insert(
			connections,
			tags.OnStateChanged:Connect(function(source: Types.DomainChangeSource)
				table.insert(sources, source)
			end)
		)
		local packetsBefore: number = actorPackets
		task.wait(0.35)
		assert(actorPackets == packetsBefore, "Countdown or onTick created recurring wire traffic")
		local later: Types.ActiveTagSnapshot? = tags:GetTag("Status.NativeTimed")
		assert(
			later ~= nil and later.remainingDuration ~= nil and later.remainingDuration < timed.remainingDuration,
			"Native countdown did not derive locally"
		)
		assert(#semantic == 0 and #sources == 0, "Countdown fabricated lifecycle or current-truth notifications")
		checkPrivacy()
	elseif phase == "LiveBatch" then
		assert(tags ~= nil, "Expected retained TagsView")
		waitFor(function(): boolean
			return #semantic == 3 and #sources == 1
		end, "Real Tag mutation batch did not reach typed events")
		local stack: Types.ActiveTagSnapshot? = tags:GetTag("Buff.NativeStack")
		assert(stack ~= nil and stack.stackCount == 2, "Native batch exposed an intermediate stack count")
		assert(sources[1] == "Commit", "Native live state source differs")
		local kinds: { [string]: number } = {}
		for _, event in semantic do
			kinds[event.id] = (kinds[event.id] or 0) + 1
			assert(
				event.stackCount == 2 and event.timedActive,
				"Native semantic callback observed partially installed batch state"
			)
		end
		assert(
			kinds.Added == 1 and kinds.Refreshed == 1 and kinds.Removed == 1 and kinds.Expired == nil,
			"Native Tag lifecycle meanings differ"
		)
		checkPrivacy()
	elseif phase == "Replacement" then
		waitFor(function(): boolean
			return baselineEnds == 2
		end, "Real replacement baseline did not arrive")
		assert(
			view ~= nil and view:GetTags() == tags and view:GetDomain("KRF.Tags") == domain,
			"Native replacement changed facade identity"
		)
		assert(#semantic == 3 and #sources == 1, "Equal replacement replayed lifecycle or state changes")
		checkPrivacy()
	elseif phase == "ManualRemoval" then
		assert(tags ~= nil, "Expected retained TagsView")
		waitFor(function(): boolean
			return not (tags :: Types.TagsView):HasTag("Buff.NativeStack") and #semantic == 4 and #sources == 2
		end, "Native manual removal did not publish")
		assert(semantic[4].id == "Removed" and semantic[4].tagId == "Buff.NativeStack", "Manual removal became expiry")
		assert(
			semantic[4].stackCount == nil and semantic[4].timedActive and sources[2] == "Commit",
			"Manual removal notification preceded installed truth or replacement fabricated a state change"
		)
		checkPrivacy()
	elseif phase == "Expiry" then
		assert(tags ~= nil, "Expected retained TagsView")
		waitFor(function(): boolean
			return not (tags :: Types.TagsView):HasTag("Status.NativeTimed") and #semantic == 5 and #sources == 3
		end, "Authoritative native expiry did not publish")
		assert(
			semantic[5].id == "Expired" and semantic[5].tagId == "Status.NativeTimed",
			"Expiry became manual removal"
		)
		assert(
			not semantic[5].timedActive and sources[3] == "Commit",
			"Expiry notification preceded authoritative state installation"
		)
		assert(#tags:GetActiveTags() == 0, "Final authoritative expiry retained a visible Tag")
		checkPrivacy()
	elseif phase == "ActorRemoval" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) == nil
		end, "Native Actor removal did not retire views")
		assert(tags ~= nil and #tags:GetActiveTags() == 0, "Removed TagsView retained current truth")
		local connected: boolean = pcall(function()
			(tags :: Types.TagsView).OnTagAdded:Connect(function() end)
		end)
		assert(not connected, "Removed TagsView still accepts subscriptions")
		staleTags = tags
	elseif phase == "Respawn" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Native respawn did not publish a fresh ActorView")
		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected respawn ActorView")
		tags = view:GetTags()
		domain = view:GetDomain("KRF.Tags")
		assert(tags ~= staleTags and tags:HasTag("Status.NativeTimed"), "Respawn revived stale TagsView")
		assert(
			staleTags ~= nil and #staleTags:GetActiveTags() == 0 and #semantic == 5,
			"Retired subscriptions rebound to respawn"
		)
		checkPrivacy()
	elseif phase == "Reset" then
		Client._ResetForTests()
		Client._ResetForTests()
		assert(
			#Registry.GetAllActorViews() == 0 and tags ~= nil and #tags:GetActiveTags() == 0,
			"Native reset retained typed state"
		)
		for _, connection: SignalTypes.Connection in connections do
			connection:Disconnect()
		end
		endpointConnection:Disconnect()
	else
		error("Unexpected native N6 phase: " .. phase, 0)
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
