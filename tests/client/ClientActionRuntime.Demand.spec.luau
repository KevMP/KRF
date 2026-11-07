--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local Installation = require(KRF.client.Action.utils.ClientActionInstallation)
local Pipeline = require(KRF.client.Input.utils.InputRecognitionPipeline)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local InputUtils = require(script.Parent.Utils.InputTestUtils)
local originalNew: typeof(Pipeline.new) = Pipeline.new
local input: InputUtils.Fixture
local actor: ActorTypes.ActorViewOwner
local other: ActorTypes.ActorViewOwner
local stopActions: () -> ()
local frames: number

beforeEach(function()
	Registry.Reset()
	frames = 0

	Pipeline.new = function(options: Pipeline.Options): Pipeline.Owner
		local measured: Pipeline.Options = table.clone(options)

		measured.DeliverEnvelope = function(envelope: InputTypes.InputCandidateEnvelope): ()
			frames += 1
			options.DeliverEnvelope(envelope)
		end

		return originalNew(measured)
	end

	input = InputUtils.new()
	Pipeline.new = originalNew
	InputState.Install(input.owner)

	stopActions = Installation.Install(function(): boolean
		return input.ready
	end)

	local definition: InputUtils.CoreDefinition = InputUtils.definition()

	definition.inputs.Move = {
		context = "Gameplay",
		type = Enum.InputActionType.Direction1D,
		bindings = { Keyboard = { keyCode = Enum.KeyCode.A } },
	}

	InputUtils.install(input, definition)
	InputUtils.enable(input)
	actor = assert(Actor.new("ActorA", nil, {}), "Expected Actor A")
	other = assert(Actor.new("ActorB", nil, {}), "Expected Actor B")
	assert(Registry.Install(actor.view), "Expected Actor A installation")
	assert(Registry.Install(other.view), "Expected Actor B installation")
end)

afterEach(function()
	Pipeline.new = originalNew
	stopActions()
	InputState.Install(nil)
	InputUtils.destroy(input)
	actor:Destroy()
	other:Destroy()
	Registry.Reset()
end)

for _, selected: boolean in { false, true } do
	it("skips unwatched analog frames with normal I4 installation and selected=" .. tostring(selected), function()
		if selected then
			expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ true })
		end

		expect({
			Runtime.SetProfileSource(other.view, "Dormant", {
				routes = {
					{
						when = { kind = "Input", inputId = "Primary", gesture = "Pressed" },
						target = { kind = "Fixed", actionId = "Other.Action" },
					},
				},
			}),
		}).toEqual({ true })

		frames = 0

		for index: number = 1, 256 do
			InputUtils.emit(input, "StateChanged", if index % 2 == 0 then 0.5 else -0.5, "Move")
		end

		expect(#input.events).toBe(256)
		expect(frames).toBe(0)
		expect(input.faults).toEqual({})
	end)
end

it("preserves unrelated envelope consumers while I4 has no routing demand", function()
	local seen: number = 0

	local stop = input.owner.ObserveCandidateEnvelope(function(envelope: InputTypes.InputCandidateEnvelope): ()
		expect(envelope.kind).toBe("Root")
		seen += 1
	end)

	InputUtils.emit(input, "StateChanged", 0.5, "Move")
	expect({ frames, seen }).toEqual({ 1, 1 })
	stop()
	InputUtils.emit(input, "StateChanged", -0.5, "Move")
	expect({ frames, seen }).toEqual({ 1, 1 })
end)

it("routes the first eligible press after selection, profile restoration and prepared profile publication", function()
	local profile: Types.ControlProfile = {
		routes = {
			{
				when = { kind = "Input", inputId = "Primary", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Combat.Punch" },
			},
		},
	}

	local owner: Types.ClientActionOwner = assert(State.Get(), "Expected normal Action installation")
	local actions: { string } = {}

	owner.ObserveSelection(function(selection: Types.ActionRouteSelection): ()
		table.insert(actions, selection.actionId)
	end)

	expect({ Runtime.SetProfileSource(actor.view, "Base", profile) }).toEqual({ true })
	InputUtils.emit(input, "StateChanged", 0.5, "Move")
	expect(frames).toBe(0)
	expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ true })
	InputUtils.emit(input, "Pressed", true)
	expect(actions).toEqual({ "Combat.Punch" })
	expect({ Runtime.RemoveProfileSource(actor.view, "Base") }).toEqual({ true })
	InputUtils.emit(input, "Released", false)
	local before: number = frames
	InputUtils.emit(input, "StateChanged", -0.5, "Move")
	expect(frames).toBe(before)
	expect({ Runtime.SetProfileSource(actor.view, "Base", profile) }).toEqual({ true })
	InputUtils.emit(input, "Pressed", true)
	expect(actions).toEqual({ "Combat.Punch", "Combat.Punch" })
	expect({ Runtime.RemoveProfileSource(actor.view, "Base") }).toEqual({ true })
	InputUtils.emit(input, "Released", false)

	local profiles: Types.PreparedProfileGraph = assert(
		owner.PrepareProfiles({ { actor = actor.view, sourceId = "Base", profile = profile } }),
		"Expected prepared profiles"
	)

	local plan: InputTypes.PreparedInputUpdate =
		assert(input.owner.PrepareSource("Empty", {}, profiles), "Expected input publication plan")

	expect({
		input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect({ owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
		end),
	}).toEqual({ true })

	InputUtils.emit(input, "Pressed", true)
	expect(actions).toEqual({ "Combat.Punch", "Combat.Punch", "Combat.Punch" })
	expect({ Runtime.SetControlledActor(nil) }).toEqual({ true })
	InputUtils.emit(input, "Released", false)
	before = frames
	InputUtils.emit(input, "StateChanged", 0.5, "Move")
	expect(frames).toBe(before)
	expect({ Runtime.SetControlledActor(actor.view) }).toEqual({ true })
	InputUtils.emit(input, "Pressed", true)
	expect(#actions).toBe(4)
end)
