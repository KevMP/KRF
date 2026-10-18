--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Client = require(KRF.client)
local Registry: Types.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Transport = require(KRF.shared.Networking.Transport)
local Protocol: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Scenario = require(ReplicatedStorage.TagsLoadScenario)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("TagsLoadControl") :: RemoteEvent
local root: Folder = ReplicatedStorage:WaitForChild(Transport.ROOT_NAME) :: Folder
local reliable: RemoteEvent = root:WaitForChild(Transport.RELIABLE_NAME) :: RemoteEvent

local phase: string = "Ready"
local failed: boolean = false
local measuring: boolean = false
local subjects: { Types.ActorView } = {}
local connections: { SignalTypes.Connection } = {}
local firstGeneration: number = 1
local rounds: number = 0
local framesMs: { number } = {}
local packets: number = 0
local bytes: number = 0
local states: number = 0
local semantic: number = 0
local typedChanges: number = 0
local seen: { [number]: { [number]: boolean } } = {}
local observed: { [number]: { number } } = {}
local waveStates: { [number]: number } = {}
local sent: { [number]: boolean } = {}
local audited: { { state: any, baseline: any, generation: number } } = {}
local kinds: { [string]: number } = {}
local actorKinds: { [number]: { [string]: number } } = {}
local caseStarted: number = 0
local bootstrapSeen: boolean = false
local completing: boolean = false

local function report(kind: string, data: any?): ()
	local message: any = data or {}
	message.kind, message.phase = kind, phase
	control:FireServer(buffer.fromstring(HttpService:JSONEncode(message)))
end

local function guard(callback: () -> ()): ()
	if failed then
		return
	end

	local completed: boolean, reason: any = pcall(callback)

	if not completed then
		failed = true
		report("Failed", { failure = tostring(reason) })
	end
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 30

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.01)
	end
end

local endpoint: RBXScriptConnection = reliable.OnClientEvent:Connect(function(payload: any)
	guard(function()
		assert(typeof(payload) == "buffer", "Expected ordinary buffer transport")
		assert(not string.find(buffer.tostring(payload), "Private.", 1, true), "Private ID leaked in framework payload")

		if buffer.readu8(payload, 0) == Constants.PACKET_KIND then
			if measuring then
				packets += 1
				bytes += buffer.len(payload)
			end
		else
			local message: SharedTypes.ProtocolMessage?, reason: string? = Protocol.Decode(payload)
			assert(message ~= nil, reason)

			if message.kind == "Bootstrap" then
				bootstrapSeen = true
				assert(#message.manifest.domains == 1, "Expected ordinary built-in Tags domain")
				local domain: SharedTypes.ManifestDomain = message.manifest.domains[1]

				assert(
					domain.id == "KRF.Tags" and domain.state.kind == "Map" and domain.state.key.kind == "Enum",
					"Unexpected schema"
				)

				assert(#domain.state.key.values == 10, "Visible codebook leaked or omitted definitions")

				for _, id: string in domain.state.key.values do
					assert(not string.find(id, "Private.", 1, true), "Private codebook ID")
				end
			end
		end
	end)
end)

local heartbeat: RBXScriptConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
	if measuring then
		table.insert(framesMs, deltaTime * 1000)
	end
end)

local function maybeComplete(): ()
	for wave: number = 1, rounds do
		-- Semantic callbacks do not promise completion order. Count the expected
		-- lifecycle vocabulary globally, and use immutable DomainChange truth to
		-- identify every applied generation even during a same-frame burst.
		if
			not sent[wave]
			and waveStates[wave] == #subjects
			and typedChanges >= wave * #subjects
			and semantic >= wave * #subjects * 4
		then
			sent[wave] = true
			report("Wave", { wave = wave, observed = observed[wave] })
		end
	end

	if
		not completing
		and states == #subjects * rounds
		and semantic == #subjects * rounds * 4
		and typedChanges == states
	then
		completing = true

		for _, snapshot in audited do
			Scenario.verifyState(snapshot.state, snapshot.generation)

			for id: string, entry: any in snapshot.state do
				if id ~= "Buff.Combo" and id ~= "Buff.Haste" and id ~= "Status.Burning" and id ~= "Status.Stunned" then
					assert(entry.expiresAt == snapshot.baseline[id].expiresAt, "Untouched timing anchor drifted")
				end
			end
		end

		for _, view: Types.ActorView in subjects do
			local tags: Types.TagsView = view:GetTags()
			local combo: Types.ActiveTagSnapshot? = tags:GetTag("Buff.Combo")
			assert(combo ~= nil and combo.stackCount == firstGeneration + rounds, "Typed current truth differs")
			assert(not tags:HasTag("Private.AIAlert") and tags:GetTag("Private.Cooldown") == nil, "Typed privacy leak")
			assert(#tags:GetActiveTags() == 9 + (firstGeneration + rounds - 1) % 2, "Typed active collection differs")
		end

		local addedStuns: number = 0

		for generation: number = firstGeneration, firstGeneration + rounds - 1 do
			if generation % 2 == 1 then
				addedStuns += 1
			end
		end

		assert(kinds["Added:Buff.Combo"] == #subjects * rounds, "Missing/duplicate Combo events")
		assert(kinds["Refreshed:Buff.Haste"] == #subjects * rounds, "Missing/duplicate refresh events")
		assert(kinds["Refreshed:Status.Burning"] == #subjects * rounds, "Missing/duplicate cap refresh events")
		assert((kinds["Added:Status.Stunned"] or 0) == #subjects * addedStuns, "Stunned add events differ")

		assert(
			(kinds["Removed:Status.Stunned"] or 0) == #subjects * (rounds - addedStuns),
			"Stunned removal events differ"
		)

		for index: number = 1, #subjects do
			local counts: { [string]: number } = actorKinds[index]
			assert(counts["Added:Buff.Combo"] == rounds, "Combo events attributed to the wrong Actor")

			assert(
				counts["Refreshed:Buff.Haste"] == rounds and counts["Refreshed:Status.Burning"] == rounds,
				"Refresh events attributed to the wrong Actor"
			)

			assert(
				(counts["Added:Status.Stunned"] or 0) == addedStuns
					and (counts["Removed:Status.Stunned"] or 0) == rounds - addedStuns,
				"Lifecycle events attributed to the wrong Actor"
			)
		end

		-- Endpoint and consumer callbacks have no promised execution order. Drain
		-- the final receive callback before freezing traffic counters. The server
		-- independently checks these against successful ordinary Actor stream sends.
		task.defer(function()
			RunService.Heartbeat:Wait()

			guard(function()
				assert(
					states == #subjects * rounds and semantic == #subjects * rounds * 4 and typedChanges == states,
					"Extra work arrived after completion"
				)

				measuring = false

				report("Done", {
					states = states,
					events = semantic,
					metrics = {
						payloadBytes = bytes,
						actorPackets = packets,
						observationSeconds = os.clock() - caseStarted,
						heartbeatMs = Scenario.summarize(framesMs),
					},
				})
			end)
		end)
	end
end

local function bind(index: number, view: Types.ActorView): ()
	local tags: Types.TagsView = view:GetTags()
	local domain: Types.DomainView? = view:GetDomain("KRF.Tags")
	assert(domain ~= nil, "Native baseline omitted Tags")
	local baseline: any = domain:GetState()
	Scenario.verifyState(baseline, 0)

	table.insert(
		connections,
		domain.OnChanged:Connect(function(change: Types.DomainChange)
			local timestamp: number = workspace:GetServerTimeNow()

			guard(function()
				assert(measuring and change.source == "Commit", "Unexpected baseline/recovery under load")
				local generation: number = change.current["Buff.Combo"].stackCount - 1
				local wave: number = generation - firstGeneration + 1
				assert(wave >= 1 and wave <= rounds, "Unexpected generation")
				local actorSeen: { [number]: boolean } = seen[index] or {}
				assert(not actorSeen[generation], "Duplicate applied generation")
				actorSeen[generation] = true
				seen[index] = actorSeen

				local times: { number } = observed[wave] or {}
				times[index] = timestamp
				observed[wave] = times
				waveStates[wave] = (waveStates[wave] or 0) + 1
				states += 1
				table.insert(audited, { state = change.current, baseline = baseline, generation = generation })
				assert(view:GetTags() == tags, "Facade identity changed")
				maybeComplete()
			end)
		end)
	)

	table.insert(
		connections,
		tags.OnStateChanged:Connect(function(source: Types.DomainChangeSource)
			guard(function()
				assert(measuring and source == "Commit", "Unexpected typed state source")
				typedChanges += 1
				maybeComplete()
			end)
		end)
	)

	for _, kind: string in { "Added", "Refreshed", "Removed", "Expired" } do
		local event: SignalTypes.Event<string> = (tags :: any)["OnTag" .. kind]

		table.insert(
			connections,
			event:Connect(function(id: string)
				guard(function()
					assert(
						measuring and not string.find(id, "Private.", 1, true),
						"Unexpected or private semantic event"
					)

					semantic += 1
					local key: string = kind .. ":" .. id

					kinds[key] = (kinds[key] or 0) + 1

					local counts: { [string]: number } = actorKinds[index] or {}
					counts[key] = (counts[key] or 0) + 1
					actorKinds[index] = counts
					maybeComplete()
				end)
			end)
		)
	end
end

control.OnClientEvent:Connect(function(payload: any)
	guard(function()
		assert(typeof(payload) == "buffer", "Expected fixture control buffer")
		local message: any = HttpService:JSONDecode(buffer.tostring(payload))
		phase = message.phase

		if message.kind == "Baseline" then
			assert(bootstrapSeen, "Normal Client.Init missed bootstrap observation")

			waitFor(function(): boolean
				if #Registry.GetAllActorViews() ~= #message.actorIds then
					return false
				end

				for _, id: string in message.actorIds do
					local view: Types.ActorView? = Registry.GetActorViewById(id)

					if view == nil or view:GetModel() == nil then
						return false
					end
				end

				return true
			end, "Normal startup did not install all ActorView consumers and Models")

			for index: number, id: string in message.actorIds do
				local view: Types.ActorView? = Registry.GetActorViewById(id)
				assert(view ~= nil, "Expected native ActorView")
				table.insert(subjects, view)
				bind(index, view)
			end

			report("Baseline")
		elseif message.kind == "Quiet" then
			packets, bytes = 0, 0
			measuring = true
			task.wait(0.65)
			measuring = false
			assert(packets == 0 and bytes == 0, "Countdown/private-only work created wire traffic")
			report("Quiet")
		elseif message.kind == "Arm" then
			firstGeneration, rounds = message.firstGeneration, message.rounds
			framesMs, seen, observed, waveStates, sent, audited, kinds, actorKinds = {}, {}, {}, {}, {}, {}, {}, {}
			packets, bytes, states, semantic, typedChanges = 0, 0, 0, 0, 0
			caseStarted = os.clock()
			completing = false
			measuring = true
			report("Armed")
		elseif message.kind == "Retire" then
			waitFor(function(): boolean
				return #Registry.GetAllActorViews() == 0
			end, "Removed native Actors remained installed")

			for _, view: Types.ActorView in subjects do
				assert(#view:GetTags():GetActiveTags() == 0, "Retired Tags retained state")
			end

			for _, connection: SignalTypes.Connection in connections do
				connection:Disconnect()
			end

			connections, subjects = {}, {}
			report("Retire")
		elseif message.kind == "Reset" then
			Client._ResetForTests()
			assert(#Registry.GetAllActorViews() == 0, "Reset retained Actors")
			endpoint:Disconnect()
			heartbeat:Disconnect()
			report("Reset")
		else
			error("Unexpected fixture phase", 0)
		end
	end)
end)

local initialized: boolean, failure: Client.StartupFailure? = Client.Init()

if initialized then
	report("Ready")
else
	report("Failed", { failure = if failure ~= nil then failure.reason else "Client.Init failed" })
end
