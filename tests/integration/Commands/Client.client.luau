--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local PublicTypes = require(KRF.client.Actor.types)
local Client = require(KRF.client)
local Diagnostics = require(KRF.client.Networking.NetworkingDiagnostics)
local DiagnosticState = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local ClientTypes = require(KRF.client.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Protocol = require(KRF.shared.Networking.ProtocolCodec)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local CommandConstants = require(KRF.shared.Networking.utils.CommandConstants)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local NetworkingTypes = require(KRF.client.Networking.types)
local Commands: NetworkingTypes.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local Hints: NetworkingTypes.HintRuntime = require(KRF.client.Networking.HintRuntime)
script.Parent:WaitForChild("Utils"):WaitForChild("ClientCorrelation")
local Correlation = require(script.Parent.Utils.ClientCorrelation)
local correlationGo: boolean = false
local control: RemoteEvent = ReplicatedStorage:WaitForChild("CommandTestControl") :: RemoteEvent
local view: PublicTypes.ActorView? = nil
local failed: boolean = false
local outcomes: { [number]: NetworkingTypes.CommandResult } = {}
local injectTerminalFailure: boolean = false
local disconnectCalls: number = 0
local discoverTransport: typeof(Native.DiscoverTransport) = Native.DiscoverTransport
local reconstruct: typeof(Manifest.Reconstruct) = Manifest.Reconstruct
local installedProtocol: SharedTypes.ClientProtocol? = nil
local hintSeen = false
local expectedHintToken: number? = nil
local expectedHintActor: string? = nil
local hintFailure: string? = nil
local s2cSeen: { [string]: boolean } = {}
local unreliableDisconnects = 0

Hints.OnHintReceived:Connect(function(received: NetworkingTypes.HintReceived): ()
	local success, failure = pcall(function(): ()
		assert(table.isfrozen(received), "Expected frozen semantic Hint receipt")

		assert(
			type(received.payload) == "number" and math.floor(received.payload / 16) == expectedHintToken,
			"S2C must reach only its selected recipient"
		)

		local targeted = received.hintId == "Game.ZLook" or received.hintId == "Game.ZPulse"

		if targeted then
			assert(
				received.actorView ~= nil
					and received.actorView:IsAvailable()
					and received.actorView:GetId() == expectedHintActor,
				"Expected current recipient-local ActorView"
			)
		else
			assert(received.actorView == nil, "None-target Hint must not expose Actor identity")
		end

		s2cSeen[received.hintId] = true
	end)

	if not success then
		hintFailure = tostring(failure)
	end
end)

-- Observe actual client reconstruction; retain the production consumer installer.
Manifest.Reconstruct = function(metadata: SharedTypes.ProtocolManifest): (SharedTypes.ClientProtocol?, string?)
	local protocol, reason = reconstruct(metadata)
	installedProtocol = protocol

	return protocol, reason
end

-- Keep native transport discovery, its connection and the production installer.
-- Inject overflow immediately after a real result so scheduler timing cannot hide it.
Native.DiscoverTransport = function(deadline: number): (ClientTypes.ClientTransport?, string?)
	local transport: ClientTypes.ClientTransport?, reason: string? = discoverTransport(deadline)

	if transport ~= nil then
		local send = transport.SendReliable

		transport.SendReliable = function(payload: buffer): ()
			local message = Protocol.Decode(payload)

			if message ~= nil and message.kind == "Ready" then
				local protocol = installedProtocol

				assert(
					protocol ~= nil and protocol.hintsById ~= nil and protocol.hintsByCode ~= nil,
					"Hints must compile before READY"
				)

				local hint = protocol.hintsById["Game.Look"]

				assert(
					hint.code == 0
						and hint.direction == "ClientToServer"
						and hint.target == "Actor"
						and hint.mode == "Latest",
					"Expected Hint metadata"
				)

				assert(hint.payloadCodec.Measure(255) == 1, "Expected compiled N1 Hint payload codec")
				assert(protocol.hintsByCode[2].id == "Game.VFX", "Expected S2C Hint codebook")
				assert(table.isfrozen(protocol.hintsById) and table.isfrozen(hint), "Hint codebooks must be immutable")
				assert(not Client._IsInitialized(), "READY must follow private protocol installation")
			end

			send(payload)
		end

		local connectHints = assert(transport.ConnectUnreliable, "Expected native unreliable observer")

		transport.ConnectUnreliable = function(callback: (any, ...any) -> ()): () -> ()
			local stop = connectHints(callback)

			return function(): ()
				unreliableDisconnects += 1
				stop()
			end
		end

		local connect: typeof(transport.ConnectReliable) = transport.ConnectReliable

		transport.ConnectReliable = function(callback: (any, ...any) -> ()): () -> ()
			local disconnect: () -> () = connect(function(payload: any, ...: any): ()
				callback(payload, ...)

				if
					injectTerminalFailure
					and typeof(payload) == "buffer"
					and buffer.len(payload) > 0
					and buffer.readu8(payload, 0) == CommandConstants.RESULT_KIND
				then
					injectTerminalFailure = false
					local overflow: buffer = buffer.create(CommandConstants.MAX_FENCED_BYTES + 1)
					buffer.writeu8(overflow, 0, ActorConstants.PACKET_KIND)
					callback(overflow)
				end
			end)

			return function(): ()
				disconnectCalls += 1
				disconnect()
			end
		end
	end

	return transport, reason
end

Commands.OnCommandResult:Connect(function(result: NetworkingTypes.CommandResult): ()
	outcomes[result.requestId] = result
end)

local function report(phase: string, failure: string?, sentIds: { number }?): ()
	control:FireServer(phase, failure, sentIds)
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 20

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.02)
	end
end

control.OnClientEvent:Connect(
	function(phase: string, actorId: string?, otherId: string?, requester: boolean?, hintToken: number?): ()
		if phase == "HintSeen" then
			hintSeen = true

			return
		end

		if failed then
			return
		end

		if phase == "Correlation" then
			correlationGo = true

			return
		end

		local reportPhase: string = phase
		local sentIds: { number }? = nil

		local completed: boolean, reason: any = pcall(function(): ()
			if phase == "Exercise" then
				assert(actorId ~= nil, "Expected native Actor identity")

				waitFor(function(): boolean
					local candidate: PublicTypes.ActorView? = Registry.GetActorViewById(actorId :: string)

					return candidate ~= nil and candidate:IsAvailable()
				end, "Normal client consumers did not install Actor views")

				view = Registry.GetActorViewById(actorId :: string)
				assert(view ~= nil, "Expected installed Hint target")
				expectedHintToken, expectedHintActor = hintToken, actorId
				control:FireServer("HintTargetsReady")

				for _, candidate in Registry.GetAllActorViews() do
					if candidate ~= view then
						assert(
							Hints.Send("Game.Look", candidate, 1),
							"Aware foreign targets may be offered but must fail server authorization"
						)
					end
				end

				-- Offer distinct samples/occurrences, not retries of a promised delivery.
				for value = 1, 4 do
					assert(Hints.Send("Game.Look", view, value), "Expected native Latest admission")
					assert(Hints.Send("Game.Pulse", nil, value), "Expected native Pulse admission")
					task.wait(0.03)
				end

				waitFor(function(): boolean
					return hintSeen
				end, "Production C2S Hint path did not deliver both modes")

				waitFor(function(): boolean
					return hintFailure ~= nil
						or (
								s2cSeen["Game.VFX"]
								and s2cSeen["Game.ZLook"]
								and s2cSeen["Game.ZPulse"]
								and s2cSeen["Game.ZSample"]
							)
							== true
				end, "Production S2C Hint path did not deliver both modes/targets")

				assert(hintFailure == nil, hintFailure)
				local first: number?, failure: string? = Commands.Send("Game.Ping")
				assert(first ~= nil and failure == nil and first > 0, "Expected raw request id after READY")
				assert(first == 1, "Hints must not allocate command request ids")
				local second: number? = nil
				second, failure = Commands.Send("Game.Interact", view, { choice = 7 })
				assert(second ~= nil and failure == nil and second > first, "Expected installed private target mapping")
				sentIds = { first, second }

				waitFor(function(): boolean
					return outcomes[first :: number] ~= nil and outcomes[second :: number] ~= nil
				end, "Native results were not delivered")

				assert(
					outcomes[first].status == "Accepted" and outcomes[first].commandId == "Game.Ping",
					"Expected correlated Ping acceptance"
				)

				assert(
					outcomes[second].status == "Accepted" and outcomes[second].targetActorView == view,
					"Expected N4-authorized exact Character target"
				)

				for _, event: any in { Commands.OnCommandResult, Commands.OnCommandUncertain } do
					assert(
						type(event.Connect) == "function"
							and type(event.Once) == "function"
							and type(event.Wait) == "function",
						"Expected KRF Event API"
					)

					for _, member: string in { "Fire", "Destroy", "DisconnectAll" } do
						local readable: boolean = pcall(function(): ()
							local _: any = event[member]
						end)

						assert(not readable, "KRF Event must reject owning-member access")
					end

					local writable: boolean = pcall(function(): ()
						event.Connect = function() end
					end)

					assert(not writable, "KRF Event must reject mutation")
				end

				local allowed: { [string]: boolean } =
					{ Send = true, OnCommandResult = true, OnCommandUncertain = true }

				for key in next, Commands :: any do
					assert(allowed[key], "Public command facade leaked private ownership or transport")
				end
			elseif phase == "PrepareCorrelation" then
				assert(actorId ~= nil and otherId ~= nil, "Expected native correlation subjects")

				Correlation.Run(actorId, otherId, requester == true, function(): ()
					report("PrepareCorrelation")
				end, function(): boolean
					return correlationGo
				end)

				reportPhase = "Correlation"
			elseif phase == "Retire" then
				assert(view ~= nil, "Expected retained native view")

				waitFor(function(): boolean
					return not (view :: PublicTypes.ActorView):IsAvailable()
				end, "Native ActorRemove was not consumed")

				local requestId: number?, failure: string? = Commands.Send("Game.Interact", view, { choice = 7 })
				assert(requestId == nil and type(failure) == "string", "Retired ActorView must fail locally")
				assert(Client._IsInitialized() and disconnectCalls == 0, "Expected live native client before overflow")
				local diagnosticOwner = assert(DiagnosticState.Get())
				local snapshot = assert(Diagnostics.GetClientSnapshot(), "Expected live client diagnostics")

				assert(
					snapshot.scope == "Client" and table.isfrozen(snapshot.counters),
					"Expected immutable client snapshot"
				)

				assert(
					snapshot.counters.reliableSendAttempts > 0 and snapshot.counters.reliableLogicalRecords > 0,
					"Expected client reliable sends"
				)

				assert(
					snapshot.counters.unreliableSendAttempts > 0 and snapshot.counters.hintRecordsAdmitted > 0,
					"Expected C2S Hint sends"
				)

				assert(
					snapshot.counters.hintPacketsAdmitted > 0 and snapshot.gauges.hintReceiveBytes.highWater > 0,
					"Expected S2C queue observations"
				)

				assert(
					snapshot.counters.commandsAccepted > 0
						and snapshot.counters.hintsReceived >= 4
						and snapshot.counters.hintsSent > 0,
					"Expected correlated outcomes and semantic Hint observations"
				)

				injectTerminalFailure = true
				requestId, failure = Commands.Send("Game.Ping")
				assert(requestId ~= nil and failure == nil, "Expected native result to trigger terminal overflow")

				waitFor(function(): boolean
					return not Client._IsInitialized() and disconnectCalls == 1
				end, "Terminal consumer failure must revoke initialization and disconnect native Reliable reception")

				Client._ResetForTests()
				Client._ResetForTests()
				assert(disconnectCalls == 1, "Repeated shutdown must not disconnect the Reliable listener twice")
				assert(unreliableDisconnects == 1, "S2C reception must disconnect exactly once")
				assert(Diagnostics.GetClientSnapshot() == nil, "Terminal shutdown must revoke client diagnostics")
				local cleaned = diagnosticOwner:Snapshot()

				assert(
					cleaned.gauges.clientCommandPending.current == 0
						and cleaned.gauges.clientCommandMetadataBytes.current == 0,
					"Shutdown must release correlation diagnostics"
				)

				assert(
					cleaned.gauges.clientBaselineBytes.current == 0
						and cleaned.gauges.clientReliableDeferredBytes.current == 0
						and cleaned.gauges.hintLatestKeys.current == 0,
					"Shutdown must release all client queue ownership observations"
				)

				requestId, failure = Commands.Send("Game.Ping")
				assert(requestId == nil and type(failure) == "string", "Shutdown must revoke command admission")
				assert(#Registry.GetAllActorViews() == 0, "Shutdown must clear Actor consumers")
			else
				error("Unexpected native command phase")
			end
		end)

		if not completed then
			failed = true
		end

		report(reportPhase, if completed then nil else tostring(reason), sentIds)
	end
)

local completed: boolean, reason: any = pcall(function(): ()
	local hintAccepted, hintReason = Hints.Send("Game.Look", nil, 1)
	assert(not hintAccepted and hintReason == "ClientNotReady", "Hint Send before Init must fail locally")
	local requestId: number?, failure: string? = Commands.Send("Game.Ping")
	assert(requestId == nil and type(failure) == "string", "Native Send before Init must fail locally")
	local initialized: boolean, startupFailure: Client.StartupFailure? = Client.Init()
	assert(initialized, if startupFailure ~= nil then startupFailure.reason else "Native Client.Init failed")
end)

Native.DiscoverTransport = discoverTransport
Manifest.Reconstruct = reconstruct
failed = not completed
report("Startup", if completed then nil else tostring(reason))
