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
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionsViewTestControl") :: RemoteEvent
local root: Folder = ReplicatedStorage:WaitForChild(Transport.ROOT_NAME) :: Folder
local reliable: RemoteEvent = root:WaitForChild(Transport.RELIABLE_NAME) :: RemoteEvent

local codec: SharedTypes.ActorStreamCodec? = nil
local actorPackets: number = 0
local baselineEnds: number = 0
local view: Types.ActorView? = nil
local actions: Types.ActionsView? = nil
local stale: Types.ActionsView? = nil
local history: { any } = {}
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

local function getActions(actorView: Types.ActorView): Types.ActionsView
	assert(type(actorView.GetActions) == "function", "Expected ActorView:GetActions")

	return actorView:GetActions()
end

-- Observe bytes on the real endpoint; Client.Init installs the actual consumer.
local endpoint: RBXScriptConnection = reliable.OnClientEvent:Connect(function(payload: any)
	if failed then
		return
	end

	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Expected framework buffer transport")

		assert(
			not string.find(buffer.tostring(payload), "Private.", 1, true),
			"Private Action identity, reason, locks or parameters leaked on wire"
		)

		if buffer.readu8(payload, 0) == Constants.PACKET_KIND then
			actorPackets += 1
			assert(codec ~= nil, "Actor stream preceded bootstrap")
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
				local schemas: SharedTypes.ActorSchemaCatalog = {}
				local found: boolean = false

				for _, definition: SharedTypes.ManifestDomain in message.manifest.domains do
					local schema: SharedTypes.CompiledSchema?, schemaReason: string? =
						SchemaCompiler.Compile(definition.state)

					assert(schema ~= nil, schemaReason)
					schemas[definition.id] = schema

					if definition.id == "KRF.Actions" then
						found = true
						local state: SharedTypes.SchemaDefinition = definition.state

						assert(
							state.kind == "Map" and state.key.kind == "U32" and state.maxEntries == 256,
							"Wrong native Actions schema"
						)

						assert(
							state.value.kind == "Enum" and #state.value.values == 4,
							"Native Actions Enum must contain visible ids only"
						)

						assert(#definition.events == 3, "Native Actions lifecycle declarations missing")
					end
				end

				assert(found, "N8 bootstrap must include KRF.Actions for ClientVisible Actions")

				local protocol: SharedTypes.ClientProtocol?, compileReason: string? =
					Manifest.Reconstruct(message.manifest)

				assert(protocol ~= nil, compileReason)
				codec = ActorCodec.Compile(protocol, schemas)
			end
		end
	end)

	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end)

local function record(kind: string, snapshot: Types.ActionSnapshot): ()
	local completed: boolean, reason: any = pcall(function()
		assert(table.isfrozen(snapshot), "Native lifecycle identity must be immutable")
		local fields: number = 0

		for key: string in snapshot :: any do
			assert(key == "actionId" or key == "sequenceId", "Private lifecycle field leaked")
			fields += 1
		end

		assert(fields == 2 and snapshot.actionId ~= "Private.Secret", "Invalid lifecycle identity")

		if snapshot.actionId == "Action.Cast" then
			assert(
				view ~= nil and view:GetResources():GetCurrent("Mana") == 80,
				"Resource state not installed before Action lifecycle"
			)

			assert(
				view:GetTags():HasTag("Casting") == (kind == "Started"),
				"Tag state not coherent with Action lifecycle"
			)
		end

		table.insert(history, { kind, snapshot.actionId, snapshot.sequenceId })
	end)

	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end

local function runPhase(message: any): ()
	local phase: string = message.phase
	local actorId: string = message.actorId

	if phase == "Initial" or phase == "Respawn" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Normal Client.Init did not install ActorView consumer")

		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected native ActorView")
		actions = getActions(view)
	end

	local currentActions: Types.ActionsView? = actions
	assert(currentActions ~= nil, "Expected native ActionsView")

	if phase == "Initial" or phase == "Respawn" then
		waitFor(function(): boolean
			return #currentActions:GetActiveActions() == 2
		end, "Active duplicates missing from native baseline")

		local first: Types.ActionSnapshot? = currentActions:GetAction(1)
		local third: Types.ActionSnapshot? = currentActions:GetAction(3)

		assert(
			first ~= nil and third ~= nil and first.actionId == "Action.A" and third.actionId == "Action.A",
			"Sequence identities collapsed"
		)

		assert(
			currentActions:GetAction(2) == nil and not currentActions:IsActionActive("Private.Secret"),
			"Typed ActionsView leaked private identity"
		)

		assert(view ~= nil, "Expected native ActorView")
		local domain: Types.DomainView? = view:GetDomain("KRF.Actions")
		assert(domain ~= nil and domain:GetState()[2] == nil, "Generic Actions DomainView leaked private identity")
		assert(#root:GetChildren() == 2, "Action-specific framework Remote introduced")

		if phase == "Initial" then
			local bindings: { { kind: string, event: SignalTypes.Event<Types.ActionSnapshot> } } = {
				{ kind = "Started", event = currentActions.OnActionStarted },
				{ kind = "Ended", event = currentActions.OnActionEnded },
				{ kind = "Interrupted", event = currentActions.OnActionInterrupted },
			}

			for _, binding in bindings do
				binding.event:Connect(function(snapshot: Types.ActionSnapshot)
					record(binding.kind, snapshot)
				end)
			end

			local before: number = actorPackets
			task.wait(0.3)

			assert(
				actorPackets == before and #history == 0,
				"Quiet Actions invented state traffic or lifecycle history"
			)
		else
			assert(
				stale ~= nil and currentActions ~= stale and #stale:GetActiveActions() == 0 and #history == 9,
				"Respawn rebound stale subscriptions"
			)
		end
	elseif phase == "Live" then
		waitFor(function(): boolean
			return #history == 6
		end, "Native batching lost immediate lifecycle events")

		local expected: { { any } } = {
			{ "Ended", "Action.A", 1 },
			{ "Started", "Action.Cast", 4 },
			{ "Started", "Action.PulseEnd", 5 },
			{ "Ended", "Action.PulseEnd", 5 },
			{ "Started", "Action.PulseInterrupt", 6 },
			{ "Interrupted", "Action.PulseInterrupt", 6 },
		}

		for index: number, item: { any } in expected do
			for field: number = 1, 3 do
				assert(history[index][field] == item[field], "Native lifecycle order differs")
			end
		end

		assert(
			#currentActions:GetActiveActions() == 2
				and currentActions:GetAction(3) ~= nil
				and currentActions:GetAction(4) ~= nil,
			"Native final active truth differs"
		)
	elseif phase == "Terminal" then
		waitFor(function(): boolean
			return #history == 8
		end, "Native terminal lifecycle missing")

		assert(
			history[7][1] == "Ended" and history[7][3] == 4 and history[8][1] == "Interrupted" and history[8][3] == 3,
			"Ended/Interrupted collapsed"
		)

		assert(#currentActions:GetActiveActions() == 0, "Terminal Actions retained active state")
	elseif phase == "Replacement" then
		waitFor(function(): boolean
			return baselineEnds >= 2
		end, "Native replacement baseline missing")

		assert(
			view ~= nil and Registry.GetActorViewById(actorId) == view and getActions(view) == currentActions,
			"Replacement changed view identity"
		)

		assert(#history == 8, "Replacement replayed lifecycle history")
	elseif phase == "AfterRecovery" then
		waitFor(function(): boolean
			return #history == 9
		end, "Subscriptions did not survive native recovery")

		assert(
			currentActions:GetAction(7) ~= nil and history[9][1] == "Started",
			"Live identity after recovery differs"
		)
	elseif phase == "Removed" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) == nil
		end, "Native removal did not retire ActorView")

		assert(#currentActions:GetActiveActions() == 0, "Removed ActionsView retained truth")

		assert(not pcall(function()
			currentActions.OnActionStarted:Connect(function() end)
		end), "Removed ActionsView accepts subscriptions")

		stale = currentActions
	elseif phase == "Reset" then
		Client._ResetForTests()
		Client._ResetForTests()

		assert(
			#Registry.GetAllActorViews() == 0 and #currentActions:GetActiveActions() == 0,
			"Reset retained native Action truth"
		)

		endpoint:Disconnect()
	else
		error("Unexpected native Actions phase: " .. phase, 0)
	end

	if not failed then
		report(phase, nil)
	end
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

if not failed then
	report("Ready", if initialized then nil elseif failure ~= nil then failure.reason else "Native Client.Init failed")
end
