--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Owner = require(KRF.client.Action.ClientActionOwner)
local Pipeline = require(KRF.client.Input.utils.InputRecognitionPipeline)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local Examples = require(ReplicatedStorage.ActionRouteExamples)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionRouteControl") :: RemoteEvent
local subjects: Folder = ReplicatedStorage:WaitForChild("ActionRouteSubjects") :: Folder
local originalNew: typeof(Owner.new) = Owner.new
local originalPipelineNew: typeof(Pipeline.new) = Pipeline.new
local recognitionFrames: number = 0
local selections: { Types.ActionRouteSelection } = {}
local latencies: { number } = {}
local boundaryStarted: number = 0
local boundaryOpen: boolean = false
local retainedReceiver: ((InputTypes.InputCandidateEnvelope) -> ())? = nil
local lastEnvelope: InputTypes.InputCandidateEnvelope? = nil
local restoreCommands: (() -> ())? = nil

local function waitFor(predicate: () -> boolean): ()
	local deadline: number = os.clock() + 8

	while not predicate() do
		assert(os.clock() < deadline, "NativeActionRouteFixtureTimeout")
		RunService.Heartbeat:Wait()
	end
end

-- Instrument the real factory. Client.Init and its consumer installer remain
-- intact. Measure final I3 envelope -> synchronous I4 sink, excluding frames.
Pipeline.new = function(options: Pipeline.Options): Pipeline.Owner
	local measured: Pipeline.Options = table.clone(options)

	measured.DeliverEnvelope = function(envelope: InputTypes.InputCandidateEnvelope): ()
		recognitionFrames += 1
		options.DeliverEnvelope(envelope)
	end

	return originalPipelineNew(measured)
end

Owner.new = function(options: Types.ClientActionOwnerOptions): Types.ClientActionOwner
	local measured: Types.ClientActionOwnerOptions = table.clone(options)

	local input: InputTypes.InputOwner = table.clone(options.Input)

	input.ObserveCandidateEnvelope = function(
		callback: (InputTypes.InputCandidateEnvelope) -> (),
		hasDemand: (() -> boolean)?
	): () -> ()
		retainedReceiver = callback

		return options.Input.ObserveCandidateEnvelope(function(envelope: InputTypes.InputCandidateEnvelope): ()
			boundaryStarted = os.clock()
			boundaryOpen = true
			lastEnvelope = envelope
			callback(envelope)
			boundaryOpen = false
		end, hasDemand)
	end

	measured.Input = input

	measured.Sink = function(selection: Types.ActionRouteSelection, parameters: any?): ()
		assert(boundaryOpen, "ActionRouteHandoffMovedToAnotherFrame")
		table.insert(latencies, (os.clock() - boundaryStarted) * 1000000)
		table.insert(selections, selection)
		options.Sink(selection, parameters)
	end

	return originalNew(measured)
end

local function run(): ()
	local initialized: boolean, failure = Client.Init()
	Owner.new = originalNew
	Pipeline.new = originalPipelineNew
	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
	local owner: Types.ClientActionOwner = assert(State.Get(), "Client.InitDidNotInstallActionOwner")
	local commands: NetworkingTypes.ClientCommandRuntime = assert(CommandState.Get(), "NativeCommandOwnerMissing")
	local send = commands.Send
	local commandCalls: number = 0

	commands.Send = function(
		self: NetworkingTypes.ClientCommandRuntime,
		commandId: string,
		target: ActorTypes.ActorView?,
		parameters: any?
	): (number?, string?)
		commandCalls += 1

		return send(self, commandId, target, parameters)
	end

	restoreCommands = function(): ()
		commands.Send = send
	end

	assert(InputState.Get() ~= nil, "InputOwnerMissing")

	waitFor(function(): boolean
		local first: any = subjects:GetAttribute("Actor1")
		local second: any = subjects:GetAttribute("Actor2")

		return type(first) == "string"
			and type(second) == "string"
			and Registry.GetActorViewById(first) ~= nil
			and Registry.GetActorViewById(second) ~= nil
	end)

	local actor: ActorTypes.ActorView =
		assert(Registry.GetActorViewById(subjects:GetAttribute("Actor1") :: string), "MissingActorA")

	local other: ActorTypes.ActorView =
		assert(Registry.GetActorViewById(subjects:GetAttribute("Actor2") :: string), "MissingActorB")

	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Parent = Players.LocalPlayer.PlayerGui

	local pad: TextButton = Instance.new("TextButton")
	pad.Parent = gui
	assert(Input.SetSource("Core", Examples.Inputs(pad)), "NativeInputsFailed")
	assert(Input.SetContextEnabled("Combat", true), "CombatContextFailed")
	assert(Input.SetContextEnabled("Signs", true), "SignsContextFailed")

	local container: Instance =
		assert(Players.LocalPlayer.PlayerScripts:FindFirstChild("KRFInputs"), "MissingNativeInputs")

	local combat: InputContext = assert(container:FindFirstChild("Combat"), "MissingCombatContext") :: InputContext
	local signs: InputContext = assert(container:FindFirstChild("Signs"), "MissingSignsContext") :: InputContext
	assert(combat.Enabled and signs.Enabled, "ConcurrentContextsNotEnabled")

	assert(
		Input.SetSource("AnalogProof", {
			inputs = { UnwatchedAxis = { context = "Combat", type = Enum.InputActionType.Direction1D, bindings = {} } },
		}),
		"AnalogProofSourceFailed"
	)

	local axis: InputAction = assert(combat:FindFirstChild("UnwatchedAxis"), "MissingAnalogProofAction") :: InputAction

	local axisDriver: InputBinding = Instance.new("InputBinding")
	axisDriver.Type = Enum.InputBindingType.Scriptable
	axisDriver.Parent = axis

	local analogUpdates: number = 0

	local analogConnection = Input.OnInput:Connect(function(event: InputTypes.SemanticInputEvent): ()
		if event.inputId == "UnwatchedAxis" and event.kind == "StateChanged" then
			analogUpdates += 1
		end
	end)

	local framesBeforeAnalog: number = recognitionFrames

	for index: number = 1, 128 do
		axisDriver:Fire(if index % 2 == 0 then 0.5 else -0.5)
	end

	waitFor(function(): boolean
		return analogUpdates == 128
	end)

	local unwatchedAnalogFrames: number = recognitionFrames - framesBeforeAnalog
	assert(unwatchedAnalogFrames == 0, "InactiveActionOwnerForcedUnwatchedRecognitionFrames")
	analogConnection:Disconnect()
	assert(Input.RemoveSource("AnalogProof"), "AnalogProofCleanupFailed")
	local equipped: string = "Technique.Rasengan"
	local resolverCalls: number = 0

	assert(
		Runtime.SetProfileSource(
			actor,
			"Core",
			Examples.Base(function(context: Types.RouteResolveContext): Types.ResolvedAction?
				assert(context.actor == actor, "ResolverActorRetargeted")
				resolverCalls += 1

				return { actionId = equipped, parameters = { techniqueId = equipped } }
			end)
		),
		"NativeProfileFailed"
	)

	assert(Runtime.SetProfileSource(other, "Core", Examples.Sword()), "InactiveActorProfileFailed")
	assert(Runtime.SetControlledActor(actor), "NativeActorSelectionFailed")

	local primary: InputAction = assert(combat:FindFirstChild("Primary"), "MissingPrimary") :: InputAction
	local keyboard: Instance = assert(primary:FindFirstChild("Keyboard"), "MissingKeyboardBinding")

	assert(
		assert(Input.GetEffectiveBindings("Primary"), "MissingBindings").Touch.definition.uiButton == pad,
		"TouchBindingMissing"
	)

	local drivers: { [string]: InputBinding } = {}

	for _, id: string in { "Primary", "Ability1", "X", "Q", "Z" } do
		local context: InputContext = if id == "Primary" or id == "Ability1" then combat else signs
		local action: Instance = assert(context:FindFirstChild(id), "MissingNativeAction")

		local driver: InputBinding = Instance.new("InputBinding")
		driver.Type = Enum.InputBindingType.Scriptable
		driver.Parent = action
		drivers[id] = driver
	end

	local function press(id: string): ()
		drivers[id]:Fire(true)
		drivers[id]:Fire(false)
	end

	local function lastAction(): string
		return assert(selections[#selections], "MissingLocalSelection").actionId
	end

	press("Primary")
	assert(lastAction() == "Combat.Punch", "BaseRouteMissing")
	assert(Runtime.SetProfileSource(actor, "Sword", Examples.Sword()), "SwordOverrideFailed")
	press("Primary")
	assert(lastAction() == "Combat.SwordSlash", "SwordDidNotOverride")

	assert(
		combat:FindFirstChild("Primary") == primary and primary:FindFirstChild("Keyboard") == keyboard,
		"ProfileRebuiltNativeInput"
	)

	assert(Runtime.RemoveProfileSource(actor, "Sword"), "SwordRemovalFailed")
	press("Primary")
	assert(lastAction() == "Combat.Punch", "BaseRouteNotRestored")
	press("Ability1")
	equipped = "Technique.Fireball"
	press("Ability1")
	assert(resolverCalls == 2 and lastAction() == "Technique.Fireball", "DynamicTargetNotResolvedAtOccurrence")
	assert(Runtime.SetProfileSource(actor, "Manual", Examples.Fireball()), "SequenceProfileFailed")
	local publicMatches: number = 0
	local releases: number = 0

	local sequenceConnection = Input.OnSequenceMatched:Connect(function()
		publicMatches += 1
	end)

	local inputConnection = Input.OnInput:Connect(function(event: InputTypes.SemanticInputEvent): ()
		if event.kind == "Released" then
			releases += 1
		end
	end)

	local before: number = #selections
	press("X")
	press("Q")
	press("Z")
	assert(#selections == before + 2 and lastAction() == "Technique.Fireball", "MappedSequenceDidNotMaskZ")

	waitFor(function(): boolean
		return publicMatches == 1 and releases == 3
	end)

	assert(Runtime.SetProfileSource(actor, "Manual", Examples.Fireball(true)), "IndependentProfileFailed")
	before = #selections
	press("X")
	press("Q")
	press("Z")
	assert(#selections == before + 3, "IndependentSequenceMaskedZ")
	drivers.Primary:Fire(true)
	assert(Runtime.SetControlledActor(other), "HeldActorSwitchFailed")
	assert(Runtime.SetControlledActor(actor), "HeldActorReturnFailed")
	before = #selections
	drivers.Primary:Fire(true)
	assert(#selections == before, "HeldActorSwitchProducedPhantomPress")
	drivers.Primary:Fire(false)
	press("Primary")
	assert(#selections == before + 1, "NativeInputDidNotRearm")
	local heapBefore: number = gcinfo()
	local started: number = os.clock()

	for _ = 1, 256 do
		press("Primary")
	end

	local nativeMilliseconds: number = (os.clock() - started) * 1000
	assert(#selections == before + 257, "SustainedNativeRoutingLostIntents")
	local heapDelta: number = gcinfo() - heapBefore
	sequenceConnection:Disconnect()
	inputConnection:Disconnect()
	control:FireServer("ReadyForRemoval")

	waitFor(function(): boolean
		return not actor:IsAvailable()
	end)

	assert(Runtime.GetControlledActor() == nil, "RemovalLeftControlledActor")
	assert(#Runtime.GetProfileSources(actor) == 0, "RemovalRetainedProfiles")

	assert(
		Runtime.GetEffectiveRoute(actor, { kind = "Input", inputId = "Primary", gesture = "Pressed" }) == nil,
		"StaleRouteInspectable"
	)

	local count: number = #selections
	assert(commandCalls == 0, "I4AttemptedN9Command")
	assert(restoreCommands, "Expected command probe cleanup")()
	Client._ResetForTests()
	assert(State.Get() == nil, "ResetRetainedActionOwner")
	assert(owner.GetControlledActor() == nil, "OldOwnerRetainedActor")
	assert(retainedReceiver, "MissingCapturedEnvelopeListener")(assert(lastEnvelope, "MissingNativeEnvelope"))
	assert(#selections == count, "OldCallbackReachedSinkAfterReset")
	gui:Destroy()
	table.sort(latencies)

	control:FireServer("Done", {
		unwatchedAnalogUpdates = analogUpdates,
		unwatchedAnalogFrames = unwatchedAnalogFrames,
		intents = count,
		samples = #latencies,
		p50EnvelopeToSinkUs = latencies[math.max(1, math.ceil(#latencies * 0.5))],
		p95EnvelopeToSinkUs = latencies[math.max(1, math.ceil(#latencies * 0.95))],
		nativeDispatchMilliseconds = nativeMilliseconds,
		heapActivityKiB = heapDelta,
	})
end

local completed: boolean, reason: any = pcall(run)
Owner.new = originalNew
Pipeline.new = originalPipelineNew

if not completed then
	if restoreCommands ~= nil then
		restoreCommands()
	end

	Client._ResetForTests()
	control:FireServer("Failure", tostring(reason))
end
