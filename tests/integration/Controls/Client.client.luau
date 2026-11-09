--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Controls.types)
local ActionTypes = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local ActorTypes = require(KRF.client.Actor.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Client = require(KRF.client)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local schemas = require(ReplicatedStorage.ControlSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ControlTestReport") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ControlTestProbe") :: RemoteFunction

local function waitFor<T>(label: string, read: () -> T?): T
	local deadline: number = os.clock() + 8

	while true do
		local result: T? = read()

		if result ~= nil then
			return result
		end

		assert(os.clock() < deadline, "ControlsWait:" .. label)
		RunService.Heartbeat:Wait()
	end
end

local function actorFor(player: Player, attribute: string): ActorTypes.ActorView
	return waitFor(attribute, function(): ActorTypes.ActorView?
		local id: unknown = player:GetAttribute(attribute)

		return if type(id) == "string" then Registry.GetActorViewById(id) else nil
	end)
end

local function driver(action: Instance): InputBinding
	local binding: InputBinding = Instance.new("InputBinding")
	binding.Type = Enum.InputBindingType.Scriptable
	binding.Name = "StudioDriver"
	binding.Parent = action

	return binding
end

local function run(): ()
	local equipped: string = "Combat.Rasengan"
	local stopCalls: number = 0
	local aim: number = 1

	local policies: ActionTypes.ActionInputPolicies = {
		["Combat.Rasengan"] = {
			activation = "WhileDown",
			startParameters = function(): { aim: number }
				return { aim = 1 }
			end,
			stopParameters = function(): { releaseAim: number }
				stopCalls += 1

				return { releaseAim = aim }
			end,
		},
		["Combat.Fireball"] = {
			startParameters = function(): { aim: number }
				return { aim = 3 }
			end,
		},
	}

	local initialized: boolean, failure =
		Client.Init({ actionRequestSchemas = schemas, actionInputPolicies = policies })

	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
	local human: ActorTypes.ActorView = actorFor(Players.LocalPlayer, "ControlHumanId")
	local mount: ActorTypes.ActorView = actorFor(Players.LocalPlayer, "ControlMountId")
	local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get(), "NormalInstallerMissingI5")
	local admissions: { RequestTypes.ActionRequestAdmission } = {}
	local outcomes: { [number]: RequestTypes.ActionRequestOutcome } = {}

	local disconnect = requests:ObserveAdmissions(function(value): ()
		table.insert(admissions, value)
	end)

	local stopOutcomes = requests:ObserveOutcomes(function(value): ()
		outcomes[value.admission.requestId] = value
	end)

	local function settle(id: number, expected: string): ()
		local outcome: RequestTypes.ActionRequestOutcome = waitFor(
			"Outcome",
			function(): RequestTypes.ActionRequestOutcome?
				local value: RequestTypes.ActionRequestOutcome? = outcomes[id]

				return if value ~= nil and value.status ~= "Unknown" then value else nil
			end
		)

		assert(outcome.status == expected, "UnexpectedOutcome:" .. outcome.status .. ":" .. tostring(outcome.reason))
	end

	assert(Input.SetSource("Core", {
		contexts = { Gameplay = { priority = 2000, sink = true } },
		inputs = {
			Ability = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = {
					Keyboard = { keyCode = Enum.KeyCode.Q },
					Gamepad = { keyCode = Enum.KeyCode.ButtonR2 },
				},
			},
			X = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.X } },
			},
		},
	}))

	assert(Input.SetContextEnabled("Gameplay", true))
	local key: ActionTypes.RouteKey = { kind = "Input", inputId = "Ability", gesture = "Pressed" }

	local profile: ActionTypes.ControlProfile = {
		routes = {
			{
				when = key,
				target = {
					kind = "Dynamic",
					resolve = function(): ActionTypes.ResolvedAction
						return { actionId = equipped }
					end,
				},
			},
		},
	}

	assert(Runtime.SetProfileSource(human, "Base", profile))
	assert(Runtime.SetProfileSource(mount, "Base", profile))
	assert(Runtime.SetControlledActor(human))
	local container: Instance = assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"))
	local context: InputContext = assert(container:FindFirstChild("Gameplay")) :: InputContext
	local action: InputAction = assert(context:FindFirstChild("Ability")) :: InputAction
	local ability: InputBinding = driver(action)
	local x: InputBinding = driver(assert(context:FindFirstChild("X")))
	ability:Fire(true)
	settle(admissions[1].requestId, "Accepted")
	assert(not human:GetActions():IsActionActive("Combat.Rasengan"), "ServerOnlyActionLeaked")
	equipped = "Combat.Fireball"
	assert(Controls.Apply({ profiles = { { kind = "Set", actor = human, sourceId = "Base", profile = profile } } }))
	assert(context:FindFirstChild("Ability") == action and #admissions == 1, "EquivalentRouteChurn")
	aim = 8
	ability:Fire(false)
	settle(admissions[2].requestId, "Accepted")

	assert(
		admissions[2].kind == "Stop" and admissions[2].originalStartRequestId == admissions[1].requestId,
		"OriginalReleaseRetargeted"
	)

	ability:Fire(true)
	ability:Fire(false)
	settle(admissions[3].requestId, "Accepted")

	equipped = "Combat.Rasengan"
	ability:Fire(true)
	local original: RequestTypes.ActionRequestAdmission = admissions[4]
	assert(Controls.Apply({ selection = { kind = "Set", actor = mount } }))

	assert(
		admissions[5].kind == "Interrupt"
			and admissions[5].originalStartRequestId == original.requestId
			and admissions[5].actor == human,
		"OriginalSwitchReceiptLost"
	)

	settle(admissions[5].requestId, "Accepted")
	ability:Fire(true)
	assert(#admissions == 5, "HeldKeyStartedMount")
	ability:Fire(false)
	equipped = "Combat.Fireball"
	ability:Fire(true)
	ability:Fire(false)
	settle(admissions[6].requestId, "Accepted")

	assert(Controls.Apply({
		inputs = {
			{
				kind = "Set",
				sourceId = "Manual",
				definition = {
					contexts = { HandSigns = { priority = 3000, sink = true } },
					inputs = {
						Sign = {
							context = "HandSigns",
							type = Enum.InputActionType.Bool,
							bindings = { Keyboard = { keyCode = Enum.KeyCode.Z } },
						},
					},
					sequences = { Cast = { steps = { "X", "Sign" }, maxGapSeconds = 1, maxTotalSeconds = 2 } },
				},
			},
		},
		profiles = {
			{
				kind = "Set",
				actor = mount,
				sourceId = "Manual",
				profile = {
					routes = {
						{
							when = { kind = "Sequence", sequenceId = "Cast" },
							target = { kind = "Fixed", actionId = "Combat.Fireball" },
						},
					},
				},
			},
		},
		contexts = { { contextId = "HandSigns", enabled = true } },
	}))

	local signs: Instance = assert(container:FindFirstChild("HandSigns"))
	local sign: InputBinding = driver(assert(signs:FindFirstChild("Sign")))
	x:Fire(true)
	x:Fire(false)
	sign:Fire(true)
	sign:Fire(false)
	settle(admissions[7].requestId, "Accepted")

	assert(Controls.Apply({
		inputs = { { kind = "Remove", sourceId = "Manual" } },
		profiles = { { kind = "Remove", actor = mount, sourceId = "Manual" } },
	}))

	assert(Input.GetSequence("Cast") == nil and container:FindFirstChild("HandSigns") == nil, "ManualLeaked")

	equipped = "Combat.Rasengan"
	ability:Fire(true)
	assert(Controls.Apply({ contexts = { { contextId = "Gameplay", enabled = false } } }))
	assert(stopCalls == 1 and admissions[9].kind == "Interrupt", "SyntheticEndBecameStop")
	settle(admissions[9].requestId, "Accepted")
	assert(Controls.Apply({ contexts = { { contextId = "Gameplay", enabled = true } } }))
	ability:Fire(false)

	assert(
		Runtime.SetProfileSource(
			mount,
			"Sword",
			{ priority = 10, routes = { { when = key, target = { kind = "Fixed", actionId = "Combat.Fireball" } } } }
		)
	)

	assert(context:FindFirstChild("Ability") == action, "StandaloneEquipRebuiltIAS")
	ability:Fire(true)
	ability:Fire(false)
	settle(admissions[10].requestId, "Accepted")

	assert(Runtime.RemoveProfileSource(mount, "Sword"))
	equipped = "Combat.Rasengan"
	ability:Fire(true)
	local beforeSink: RequestTypes.ActionRequestAdmission = admissions[11]
	settle(beforeSink.requestId, "Accepted")

	assert(Controls.Apply({
		inputs = {
			{
				kind = "Set",
				sourceId = "Menu",
				definition = {
					contexts = { Menu = { priority = 4000, sink = true } },
					inputs = {
						Confirm = {
							context = "Menu",
							type = Enum.InputActionType.Bool,
							bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
						},
					},
				},
			},
		},
		contexts = { { contextId = "Menu", enabled = true } },
	}))

	assert(
		admissions[12].kind == "Interrupt"
			and admissions[12].originalStartRequestId == beforeSink.requestId
			and stopCalls == 1,
		"SinkTakeoverBecameStopOrStrandedAction"
	)

	settle(admissions[12].requestId, "Accepted")
	assert(Controls.Apply({ contexts = { { contextId = "Menu", enabled = false } } }))
	ability:Fire(true)
	assert(#admissions == 12, "SinkRestorationRearmedHeldInput")
	ability:Fire(false)
	equipped = "Combat.Fireball"
	ability:Fire(true)
	ability:Fire(false)
	settle(admissions[13].requestId, "Accepted")
	assert(Controls.Apply({ inputs = { { kind = "Remove", sourceId = "Menu" } } }))

	local response: unknown = probe:InvokeServer()
	assert(type(response) == "table", "MissingNativeLedger")
	local ledger: { [string]: unknown } = response :: { [string]: unknown }

	assert(
		ledger.starts == 4 and ledger.stops == 1 and ledger.interrupts == 3 and ledger.fireballs == 5,
		"NativeLedgerMismatch"
	)

	local peer: Player = waitFor("Peer", function(): Player?
		for _, player in Players:GetPlayers() do
			if player ~= Players.LocalPlayer then
				return player
			end
		end

		return nil
	end)

	local unauthorized: number =
		assert(Runtime.RequestAction(actorFor(peer, "ControlHumanId"), "Combat.Rasengan", { aim = 99 }))

	settle(unauthorized, "Rejected")
	disconnect()
	stopOutcomes()
	Client._ResetForTests()
	assert(RequestState.Get() == nil and container.Parent == nil, "ControlTeardownLeaked")
	assert(Controls.Apply({}) == false, "StaleFacadeStillReady")
end

local completed: boolean, reason: unknown = pcall(run)
Client._ResetForTests()
control:FireServer(if completed then {} else { failure = tostring(reason) })
