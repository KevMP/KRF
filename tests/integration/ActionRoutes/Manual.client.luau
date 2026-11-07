--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Examples = require(ReplicatedStorage.ActionRouteExamples)
local subjects: Folder = ReplicatedStorage:WaitForChild("ActionRouteSubjects") :: Folder

local gui: ScreenGui = Instance.new("ScreenGui")
gui.Name = "ActionRouteManual"
gui.ResetOnSpawn = false
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local panel: Frame = Instance.new("Frame")
panel.Position = UDim2.fromScale(0.03, 0.03)
panel.Size = UDim2.fromScale(0.75, 0.9)
panel.BackgroundColor3 = Color3.fromRGB(20, 28, 42)
panel.Parent = gui

local layout: UIListLayout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = panel

local function label(text: string, height: number): TextLabel
	local result: TextLabel = Instance.new("TextLabel")
	result.Size = UDim2.new(1, 0, 0, height)
	result.BackgroundTransparency = 1
	result.TextColor3 = Color3.new(1, 1, 1)
	result.TextWrapped = true
	result.TextSize = 16
	result.Text = text
	result.Parent = panel

	return result
end

label(
	"I4 physical-device checks: F / left mouse / gamepad R2 / touch pad selects Punch. Equip sword selects SwordSlash with the same native input. Hold F while switching A/B: no phantom press; release and press again to rearm. X Q Z maps Fireball and masks only Z's Action, with public sequence and release still visible. Independent mode also selects Z. E resolves the current technique. These are local selections, not server Starts.",
	130
)

local status: TextLabel = label("Initializing...", 70)
local history: TextLabel = label("No selections", 70)

local pad: TextButton = Instance.new("TextButton")
pad.Text = "Touch / mouse Primary"
pad.Size = UDim2.new(1, 0, 0, 45)
pad.Parent = panel

local initialized: boolean, failure = Client.Init()
assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
local owner: Types.ClientActionOwner = assert(State.Get(), "Client.InitDidNotInstallActionOwner")
local deadline: number = os.clock() + 10

while Registry.GetAllActorViews()[2] == nil do
	assert(os.clock() < deadline, "ManualActorViewsMissing")
	task.wait()
end

local actor: ActorTypes.ActorView =
	assert(Registry.GetActorViewById(subjects:GetAttribute("Actor1") :: string), "MissingActorA")

local other: ActorTypes.ActorView =
	assert(Registry.GetActorViewById(subjects:GetAttribute("Actor2") :: string), "MissingActorB")

assert(Input.SetSource("Core", Examples.Inputs(pad)), "ManualInputsFailed")
assert(Input.SetContextEnabled("Combat", true), "CombatContextFailed")
assert(Input.SetContextEnabled("Signs", true), "SignsContextFailed")
local equipped: string = "Technique.Rasengan"
local selected: ActorTypes.ActorView = actor
local sword: boolean = false
local independent: boolean = false
local sequenceCount: number = 0
local releaseCount: number = 0
local lines: { string } = {}

for _, view: ActorTypes.ActorView in { actor, other } do
	assert(
		Runtime.SetProfileSource(
			view,
			"Core",
			Examples.Base(function(): Types.ResolvedAction?
				return { actionId = equipped }
			end)
		),
		"ManualBaseProfileFailed"
	)

	assert(Runtime.SetProfileSource(view, "Manual", Examples.Fireball()), "ManualSequenceProfileFailed")
end

assert(Runtime.SetControlledActor(actor), "ManualSelectionFailed")

local function refresh(): ()
	status.Text = string.format(
		"Actor %s | target %s | public sequences %d | genuine releases %d",
		if Runtime.GetControlledActor() == actor
			then "A"
			elseif Runtime.GetControlledActor() == other then "B"
			else "nil",
		equipped,
		sequenceCount,
		releaseCount
	)
end

owner.ObserveSelection(function(selection: Types.ActionRouteSelection): ()
	table.insert(lines, selection.actionId .. " @ " .. (if selection.actor == actor then "A" else "B"))

	if #lines > 4 then
		table.remove(lines, 1)
	end

	history.Text = table.concat(lines, "\n")
end)

Input.OnSequenceMatched:Connect(function()
	sequenceCount += 1
	refresh()
end)

Input.OnInput:Connect(function(event: InputTypes.SemanticInputEvent): ()
	if event.kind == "Released" then
		releaseCount += 1
		refresh()
	end
end)

local function button(text: string, callback: () -> ()): ()
	local control: TextButton = Instance.new("TextButton")
	control.Text = text
	control.Size = UDim2.new(1, 0, 0, 35)
	control.Parent = panel

	control.Activated:Connect(function(): ()
		callback()
		refresh()
	end)
end

button("Equip / unequip sword for selected Actor", function(): ()
	sword = not sword

	if sword then
		assert(Runtime.SetProfileSource(selected, "Sword", Examples.Sword()), "SwordInstallFailed")
	else
		assert(Runtime.RemoveProfileSource(selected, "Sword"), "SwordRemovalFailed")
	end
end)

button("Switch Actor A / B while holding F", function(): ()
	selected = if selected == actor then other else actor
	assert(Runtime.SetControlledActor(selected), "ActorSwitchFailed")
end)

button("Select nil / restore selected Actor", function(): ()
	assert(
		Runtime.SetControlledActor(if Runtime.GetControlledActor() == nil then selected else nil),
		"NilSelectionFailed"
	)
end)

button("Fireball Exclusive / Independent", function(): ()
	independent = not independent
	assert(Runtime.SetProfileSource(selected, "Manual", Examples.Fireball(independent)), "DispatchModeFailed")
end)

button("Change game-owned target without changing the dynamic route", function(): ()
	equipped = if equipped == "Technique.Rasengan" then "Technique.Fireball" else "Technique.Rasengan"
end)

refresh()
