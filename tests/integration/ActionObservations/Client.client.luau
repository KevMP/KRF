--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Controls = require(KRF.client.Controls.ClientControls)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local schemas = require(ReplicatedStorage.ObservationSchemas)
local report: RemoteEvent = ReplicatedStorage:WaitForChild("ObservationReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ObservationProbe") :: RemoteFunction

local function waitFor<T>(label: string, read: () -> T?): T
	local deadline: number = os.clock() + 8

	while true do
		local value: T? = read()

		if value ~= nil then
			return value
		end

		assert(os.clock() < deadline, "ObservationWait:" .. label)
		RunService.Heartbeat:Wait()
	end
end

local function actorFor(player: Player, attribute: string): ActorTypes.ActorView
	return waitFor(attribute, function(): ActorTypes.ActorView?
		local id: unknown = player:GetAttribute(attribute)

		return if type(id) == "string" then Registry.GetActorViewById(id) else nil
	end)
end

local function driver(container: Instance, name: string): InputBinding
	local action: Instance = assert(container:FindFirstChild(name), "MissingNativeAction:" .. name)
	local binding: InputBinding = Instance.new("InputBinding")
	assert(action:IsA("InputAction"), "ExpectedManagedIASAction")
	binding.Name = "StudioDriver"
	binding.Type = Enum.InputBindingType.Scriptable
	binding.Parent = action

	return binding
end

local function run(): ()
	local initialized: boolean, failure = Client.Init({
		actionRequestSchemas = schemas,
		actionInputPolicies = {
			["Combat.Rasengan"] = {
				activation = "WhileDown",
				startParameters = function(): any
					return { aim = 1 }
				end,
				stopParameters = function(): any
					return { releaseAim = 8 }
				end,
			},
			["Combat.Fireball"] = {
				startParameters = function(): any
					return { aim = 3 }
				end,
			},
			["Movement.Sprint"] = { activation = "WhileDown" },
			["Mode.Aura"] = { activation = "Toggle" },
		},
	})

	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
	assert(RequestState.Get() ~= nil and State.GetInput() ~= nil, "NormalInstallerMissingOwners")
	local actor: ActorTypes.ActorView = actorFor(Players.LocalPlayer, "ObservationActorA")
	local other: ActorTypes.ActorView = actorFor(Players.LocalPlayer, "ObservationActorB")
	local public: { Types.ActionRequestEvent } = {}
	local private: { Types.ActionRequestEvent } = {}
	local results: { [number]: Types.ActionRequestOutcome } = {}

	local connection = Runtime.OnActionRequest:Connect(function(fact: Types.ActionRequestEvent): ()
		table.insert(public, fact)

		if fact.kind == "RequestOutcome" then
			results[fact.requestId] = fact
		end
	end)

	local function settle(id: number): Types.ActionRequestOutcome
		return waitFor("Outcome" .. id, function(): Types.ActionRequestOutcome?
			local result: Types.ActionRequestOutcome? = results[id]

			return if result ~= nil and result.status ~= "Unknown" then result else nil
		end)
	end

	-- No Presentation or private subscriber is needed for normal Client.Init or
	-- direct requests. Immediate server End must not become fabricated active state.
	local initialResult: { status: string, sequenceId: number? }?

	local stopInitial = assert(RequestState.Get(), "Expected installed I5 owner"):ObserveOutcomes(function(outcome): ()
		if outcome.admission.requestId == 1 then
			initialResult = { status = outcome.status, sequenceId = outcome.sequenceId }
		end
	end)

	local first: number = assert(Runtime.RequestAction(actor, "Combat.Fireball", { aim = 2 }))

	local authoritative = waitFor("OriginalI5Result", function(): { status: string, sequenceId: number? }?
		return initialResult
	end)

	stopInitial()
	assert(authoritative.status == "Accepted" and authoritative.sequenceId ~= nil, "NativeDirectRequestNotAccepted")
	RunService.Heartbeat:Wait()
	assert(#public == 2, "MissingPublicFactsForAcceptedDirectStart")
	local firstResult: Types.ActionRequestOutcome = settle(first)
	assert(firstResult.status == "Accepted" and firstResult.operation == "Start", "DirectStartFailed")
	assert(type(firstResult.sequenceId) == "number", "MissingAuthoritativeSequence")
	assert(not actor:GetActions():IsActionActive("Combat.Fireball"), "ImmediateEndBecameLocallyActive")
	local publicOffset: number = #public
	assert(publicOffset == 2, "DuplicateDirectAdmission")

	local coherentSwitch: boolean = false

	local stop = State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
		table.insert(private, fact)

		if fact.kind == "InputTransition" and fact.transition == "InvalidatedInterrupt" then
			coherentSwitch = Runtime.GetControlledActor() == other
				and assert(InputState.Get()).GetCommitContext() == nil
		end
	end)

	assert(Input.SetSource("Core", {
		contexts = { Combat = { priority = 2000, sink = true } },
		inputs = {
			Q = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
			},
			X = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.X } },
			},
			Z = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Z } },
			},
			Toggle = { context = "Combat", type = Enum.InputActionType.Bool, bindings = {} },
		},
		sequences = { Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 1, maxTotalSeconds = 3 } },
	}))

	assert(Input.SetContextEnabled("Combat", true))
	local equipped: string = "Combat.Rasengan"

	local profile: Types.ControlProfile = {
		routes = {
			{
				when = { kind = "Input", inputId = "Q", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Movement.Sprint" },
			},
			{
				when = { kind = "Sequence", sequenceId = "Cast" },
				target = {
					kind = "Dynamic",
					resolve = function(): Types.ResolvedAction
						return { actionId = equipped }
					end,
				},
			},
			{
				when = { kind = "Input", inputId = "Toggle", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Mode.Aura" },
			},
		},
	}

	assert(Runtime.SetProfileSource(actor, "Base", profile))
	assert(Runtime.SetProfileSource(other, "Base", profile))
	assert(Runtime.SetControlledActor(actor))
	local container: Instance = assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"))
	local context: Instance = assert(container:FindFirstChild("Combat"))
	local q: InputBinding = driver(context, "Q")
	local x: InputBinding = driver(context, "X")
	local z: InputBinding = driver(context, "Z")
	local toggle: InputBinding = driver(context, "Toggle")

	q:Fire(true)
	assert(#private == 1 and private[1].kind == "RequestAdmitted", "AdmissionAddedFrame")
	q:Fire(false)
	assert(#private == 3 and private[2].kind == "InputTransition", "MissingOriginalReleaseBeforeAck")
	local sprint: Types.ActionRequestAdmitted = private[1] :: Types.ActionRequestAdmitted
	local sprintStop: Types.ActionRequestAdmitted = private[3] :: Types.ActionRequestAdmitted
	local sprintResult: Types.ActionRequestOutcome = settle(sprint.requestId)
	assert(settle(sprintStop.requestId).status == "Accepted", "StopFailed")
	assert(sprintResult.operation == "Start" and sprintResult.status == "Accepted", "SprintStartNotAccepted")

	waitFor("NonterminalStop", function(): ActorTypes.ActionSnapshot?
		return actor:GetActions():GetAction(sprintResult.sequenceId)
	end)

	local function signs(releaseFinal: boolean): ()
		x:Fire(true)
		x:Fire(false)
		q:Fire(true)
		q:Fire(false)
		z:Fire(true)

		if releaseFinal then
			z:Fire(false)
		end
	end

	local beforeSigns: number = #private
	signs(false)
	local charge: Types.ActionRequestEvent = private[#private]
	assert(charge.kind == "RequestAdmitted" and charge.actionId == "Combat.Rasengan", "FinalZDidNotAdmitOriginal")
	assert(charge.inputOccurredAt ~= nil and charge.origin == "Input", "MissingOriginalRecognitionTime")
	equipped = "Combat.Fireball"
	assert(Controls.Apply({ profiles = { { kind = "Set", actor = actor, sourceId = "Base", profile = profile } } }))
	local beforeRelease: number = #private
	z:Fire(false)
	assert(#private == beforeRelease + 2, "OriginalReleaseNotSameStack")
	local release: Types.ActionRequestEvent = private[beforeRelease + 1]

	assert(
		release.kind == "InputTransition"
			and release.transition == "GenuineRelease"
			and release.actionId == "Combat.Rasengan",
		"ReleaseRetargeted"
	)

	local chargeStop: Types.ActionRequestAdmitted = private[#private] :: Types.ActionRequestAdmitted

	assert(
		settle(charge.requestId).status == "Accepted" and settle(chargeStop.requestId).status == "Accepted",
		"OriginalChargeOrStopNotAccepted"
	)

	assert(not actor:GetActions():IsActionActive("Combat.Rasengan"), "ServerOnlyActionLeaked")
	assert(beforeRelease > beforeSigns, "MissingSignsAdmission")
	local ledger: any = probe:InvokeServer("Ledger")
	assert(ledger.releaseAim == 8, "OriginalStopParametersLost")

	toggle:Fire(true)
	toggle:Fire(false)
	local aura: Types.ActionRequestAdmitted = private[#private] :: Types.ActionRequestAdmitted
	toggle:Fire(true)
	toggle:Fire(false)
	local auraStop: Types.ActionRequestAdmitted = private[#private] :: Types.ActionRequestAdmitted
	assert(private[#private - 1].kind == "InputTransition", "ToggleOffMissing")

	assert(
		(private[#private - 1] :: Types.ActionInputTransition).transition == "ToggleOff",
		"ToggleBecameGenuineRelease"
	)

	settle(aura.requestId)
	settle(auraStop.requestId)

	equipped = "Combat.Rasengan"
	signs(false)
	local switched: Types.ActionRequestAdmitted = private[#private] :: Types.ActionRequestAdmitted
	assert(Controls.Apply({ selection = { kind = "Set", actor = other } }))
	assert(coherentSwitch, "PresentationObservedNativeMutationFence")
	local interrupt: Types.ActionRequestAdmitted = private[#private] :: Types.ActionRequestAdmitted

	assert(
		interrupt.operation == "Interrupt"
			and interrupt.actor == actor
			and interrupt.originalStartKey == switched.originalStartKey,
		"OriginalSwitchIdentityLost"
	)

	settle(interrupt.requestId)
	z:Fire(false)

	local peer: Player = waitFor("Peer", function(): Player?
		for _, player: Player in Players:GetPlayers() do
			if player ~= Players.LocalPlayer then
				return player
			end
		end

		return nil
	end)

	local denied: number = assert(Runtime.RequestAction(actorFor(peer, "ObservationActorA"), "Movement.Sprint"))
	assert(settle(denied).status == "Rejected", "ForeignActorAuthorityBypassed")

	-- NPC ActionsView alone can drive remote presentation. A server-owned Start
	-- neither needs nor manufactures a local Action request observation.
	local npc: ActorTypes.ActorView = waitFor("NPCView", function(): ActorTypes.ActorView?
		local id: unknown = ReplicatedStorage:GetAttribute("ObservationNPCId")

		return if type(id) == "string" then Registry.GetActorViewById(id) else nil
	end)

	local beforeNPC: number = #private
	local npcReply: any = probe:InvokeServer("NPC")

	waitFor("NPCAction", function(): ActorTypes.ActionSnapshot?
		return npc:GetActions():GetAction(npcReply.npcSequenceId)
	end)

	assert(#private == beforeNPC, "RemoteStateManufacturedLocalIntent")

	waitFor("PublicParity", function(): boolean?
		return if #public == publicOffset + #private then true else nil
	end)

	local ordered: { Types.ActionRequestEvent } = {}

	for index = publicOffset + 1, #public do
		table.insert(ordered, public[index])
	end

	table.sort(ordered, function(left: Types.ActionRequestEvent, right: Types.ActionRequestEvent): boolean
		return left.eventOrdinal < right.eventOrdinal
	end)

	for index, fact: Types.ActionRequestEvent in ordered do
		assert(table.isfrozen(fact), "MutablePublicFact")

		for key: string, value: unknown in (fact :: unknown) :: { [string]: unknown } do
			assert(
				((private[index] :: unknown) :: { [string]: unknown })[key] == value,
				"PublicPrivateFactMismatch:" .. key
			)
		end
	end

	local pending: number = assert(Runtime.RequestAction(other, "Combat.Fireball", { aim = 1 }))
	Client._ResetForTests()
	local closed: Types.ActionRequestEvent = private[#private]

	assert(
		closed.kind == "RequestOutcome" and closed.requestId == pending and closed.status == "Unknown",
		"ClosingLostI5Uncertainty"
	)

	assert(RequestState.Get() == nil and container.Parent == nil, "ObservationTeardownLeaked")
	stop()
	connection:Disconnect()
end

local completed: boolean, reason: unknown = pcall(run)
Client._ResetForTests()
report:FireServer(if completed then nil else tostring(reason))
