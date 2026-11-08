--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local SharedRequestTypes = require(KRF.shared.ActionRequest.types)
local Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local schemas = require(ReplicatedStorage.ActionInputSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionInputControl") :: RemoteEvent
local probe: RemoteFunction = ReplicatedStorage:WaitForChild("ActionInputProbe") :: RemoteFunction

type DirectRuntime = {
	RequestAction: (ActorTypes.ActorView, string, any?) -> (number?, string?),
	RequestStop: (number, any?) -> (number?, string?),
	RequestInterrupt: (number, SharedRequestTypes.ActionInputInterruptReason) -> (number?, string?),
}

local function waitFor<T>(label: string, read: () -> T?): T
	local deadline: number = os.clock() + 8

	while true do
		local value: T? = read()

		if value ~= nil then
			return value
		end

		assert(os.clock() < deadline, "NativeActionInputWait:" .. label)
		RunService.Heartbeat:Wait()
	end
end

local function actorFor(player: Player): ActorTypes.ActorView
	return waitFor(player.Name, function(): ActorTypes.ActorView?
		local id: any = player:GetAttribute("ActionInputActorId")

		return if type(id) == "string" then Registry.GetActorViewById(id) else nil
	end)
end

local function run(): any
	local aim: number = 1
	local equipped: string = "Combat.Rasengan"
	local stopCalls: number = 0

	local policies: Types.ActionInputPolicies = {
		["Combat.Rasengan"] = {
			activation = "WhileDown",
			startParameters = function(): any
				return { aim = aim }
			end,
			stopParameters = function(context): any
				assert(context.actionId == "Combat.Rasengan", "ReleaseRetargetedToEquipment")
				stopCalls += 1

				return { releaseAim = aim }
			end,
		},
		["Combat.Fireball"] = {
			startParameters = function(): any
				return { aim = aim }
			end,
		},
		["Mode.Aura"] = { activation = "Toggle" },
	}

	local initialized: boolean, failure =
		Client.Init({ actionRequestSchemas = schemas, actionInputPolicies = policies })

	assert(initialized, if failure ~= nil then failure.reason else "NativeClientInitFailed")
	local requests: RequestTypes.ClientActionRequestRuntime = assert(RequestState.Get(), "NormalInstallerMissingI5")
	local admissions: { RequestTypes.ActionRequestAdmission } = {}
	local outcomes: { [number]: RequestTypes.ActionRequestOutcome } = {}

	requests:ObserveAdmissions(function(admission): ()
		table.insert(admissions, admission)
	end)

	requests:ObserveOutcomes(function(outcome): ()
		outcomes[outcome.admission.requestId] = outcome
	end)

	local function settled(id: number, expected: string): RequestTypes.ActionRequestOutcome
		local outcome: RequestTypes.ActionRequestOutcome = waitFor(
			"Outcome:" .. id,
			function(): RequestTypes.ActionRequestOutcome?
				local result: RequestTypes.ActionRequestOutcome? = outcomes[id]

				return if result ~= nil and result.status ~= "Unknown" then result else nil
			end
		)

		assert(outcome.status == expected, "NativeOutcome:" .. outcome.status .. ":" .. tostring(outcome.reason))

		return outcome
	end

	local actor: ActorTypes.ActorView = actorFor(Players.LocalPlayer)

	local other: ActorTypes.ActorView = waitFor("Peer", function(): ActorTypes.ActorView?
		for _, player: Player in Players:GetPlayers() do
			if player ~= Players.LocalPlayer then
				local id: any = player:GetAttribute("ActionInputActorId")

				return if type(id) == "string" then Registry.GetActorViewById(id) else nil
			end
		end

		return nil
	end)

	local inputs: { [string]: InputTypes.InputDefinition } = {}

	for _, id: string in { "AbilitySlot1", "Aura", "X", "Q", "Z" } do
		inputs[id] = {
			context = "Combat",
			type = Enum.InputActionType.Bool,
			bindings = { Keyboard = { keyCode = Enum.KeyCode.Z }, Gamepad = { keyCode = Enum.KeyCode.ButtonR2 } },
		}
	end

	assert(Input.SetSource("Core", {
		contexts = { Combat = { priority = 2000, sink = true } },
		inputs = inputs,
		sequences = { Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 } },
	}))

	assert(Input.SetContextEnabled("Combat", true))
	local container: Instance = assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"))
	local context: InputContext = assert(container:FindFirstChild("Combat")) :: InputContext
	local drivers: { [string]: InputBinding } = {}

	for id: string in inputs do
		local driver: InputBinding = Instance.new("InputBinding")
		driver.Type = Enum.InputBindingType.Scriptable
		driver.Parent = assert(context:FindFirstChild(id))
		drivers[id] = driver
	end

	local function tap(id: string): ()
		drivers[id]:Fire(true)
		drivers[id]:Fire(false)
	end

	local profile: Types.ControlProfile = {
		routes = {
			{
				when = { kind = "Input", inputId = "AbilitySlot1", gesture = "Pressed" },
				target = {
					kind = "Dynamic",
					resolve = function(): Types.ResolvedAction
						return { actionId = equipped }
					end,
				},
			},
			{
				when = { kind = "Sequence", sequenceId = "Cast" },
				target = { kind = "Fixed", actionId = "Combat.Rasengan" },
			},
			{
				when = { kind = "Input", inputId = "Z", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Combat.Fireball" },
			},
			{
				when = { kind = "Input", inputId = "Aura", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Mode.Aura" },
			},
		},
	}

	assert(Runtime.SetProfileSource(actor, "Core", profile))
	assert(Runtime.SetControlledActor(actor))
	drivers.AbilitySlot1:Fire(true)
	assert(#admissions == 1 and admissions[1].kind == "Start", "SelectedActionDidNotAdmitStartOnInputStack")
	local original: number = admissions[1].requestId
	equipped = "Combat.Fireball"
	aim = 8
	drivers.AbilitySlot1:Fire(false)

	assert(
		#admissions == 2 and admissions[2].originalStartRequestId == original and admissions[2].kind == "Stop",
		"EarlyReleaseLostOriginalReceipt"
	)

	settled(original, "Accepted")
	settled(admissions[2].requestId, "Accepted")
	local snapshot: any = probe:InvokeServer()
	assert(snapshot.releasedStillActive and snapshot.releases[1] == 8, "TypedStopWasNotNonterminal")
	assert(not actor:GetActions():IsActionActive("Combat.Rasengan"), "ServerOnlyActionLeaked")
	tap("AbilitySlot1")
	assert(#admissions == 3 and admissions[3].actionId == "Combat.Fireball", "NextPressDidNotChooseConcreteOneShot")
	settled(admissions[3].requestId, "Accepted")
	equipped = "Combat.Rasengan"
	drivers.AbilitySlot1:Fire(true)
	assert(Runtime.RemoveProfileSource(actor, "Core"))
	assert(#admissions == 5 and admissions[5].kind == "Interrupt" and stopCalls == 1, "RouteRemovalFabricatedRelease")
	settled(admissions[5].requestId, "Accepted")
	drivers.AbilitySlot1:Fire(false)
	assert(Runtime.SetProfileSource(actor, "Core", profile))
	tap("X")
	tap("Q")
	drivers.Z:Fire(true)
	assert(#admissions == 6 and admissions[6].actionId == "Combat.Rasengan", "FinalZDidNotMaskOrdinaryFireball")
	drivers.Z:Fire(false)
	assert(#admissions == 7 and admissions[7].kind == "Stop", "FinalZReleaseMissing")
	settled(admissions[7].requestId, "Accepted")
	tap("Aura")
	tap("Aura")
	assert(#admissions == 9 and admissions[8].kind == "Start" and admissions[9].kind == "Stop", "NativeToggleNotPaired")
	settled(admissions[9].requestId, "Accepted")
	drivers.AbilitySlot1:Fire(true)
	assert(Runtime.SetControlledActor(other))
	assert(Runtime.SetControlledActor(actor))
	local count: number = #admissions
	drivers.AbilitySlot1:Fire(true)
	drivers.AbilitySlot1:Fire(false)

	assert(
		#admissions == count and admissions[count].kind == "Interrupt" and stopCalls == 2,
		"ActorSwitchCreatedPhantomPressOrRelease"
	)

	settled(admissions[count].requestId, "Accepted")
	local direct: DirectRuntime = (Runtime :: unknown) :: DirectRuntime
	assert(type(direct.RequestAction) == "function", "DirectActionConvenienceMissing")
	local fireball: number = assert(direct.RequestAction(actor, "Combat.Fireball", { aim = 12 }))
	settled(fireball, "Accepted")
	local denied: number = assert(direct.RequestAction(actor, "Combat.Fireball", { aim = 99 }))
	assert(settled(denied, "Rejected").reason == "GameDenied", "GameCanStartAuthorityBypassed")
	local ungranted: number = assert(direct.RequestAction(actor, "Movement.Sprint"))
	assert(settled(ungranted, "Rejected").reason == "ActionNotGranted", "ActionGrantAuthorityBypassed")
	local foreign: number = assert(direct.RequestAction(other, "Combat.Rasengan", { aim = 1 }))
	assert(settled(foreign, "Rejected").reason == "ActorNotOwned", "ForeignActorAuthorityBypassed")
	Client._ResetForTests()
	assert(RequestState.Get() == nil, "TeardownRetainedRequestRuntime")

	return { stopCalls = stopCalls }
end

local completed: boolean, report: any = pcall(run)
Client._ResetForTests()
control:FireServer(if completed then report else { failure = tostring(report) })
