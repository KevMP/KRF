--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local KRF = ReplicatedStorage.Packages.KRF
local Client = require(KRF.client)
local Types = require(KRF.client.Input.types)
local Input: Types.InputRuntime = require(KRF.client.Input.InputRuntime)
local State = require(KRF.client.Input.utils.InputRuntimeState)

local background: Color3 = Color3.fromRGB(13, 21, 35)
local panel: Color3 = Color3.fromRGB(24, 37, 56)
local textColor: Color3 = Color3.fromRGB(226, 236, 247)
local accent: Color3 = Color3.fromRGB(91, 224, 185)

local gui: ScreenGui = Instance.new("ScreenGui")
gui.Name = "GestureManual"
gui.ResetOnSpawn = false
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local scroll: ScrollingFrame = Instance.new("ScrollingFrame")
scroll.Name = "Panel"
scroll.AnchorPoint = Vector2.new(0.5, 0.5)
scroll.Position = UDim2.fromScale(0.5, 0.5)
scroll.Size = UDim2.fromScale(0.94, 0.92)
scroll.BackgroundColor3 = background
scroll.BorderSizePixel = 0
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.ScrollBarThickness = 6
scroll.Parent = gui

local padding: UIPadding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 18)
padding.PaddingRight = UDim.new(0, 18)
padding.PaddingTop = UDim.new(0, 18)
padding.PaddingBottom = UDim.new(0, 18)
padding.Parent = scroll

local layout: UIListLayout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll

local diagnostics: ScrollingFrame = Instance.new("ScrollingFrame")
diagnostics.Name = "Diagnostics"
diagnostics.BackgroundColor3 = background
diagnostics.BorderSizePixel = 0
diagnostics.AutomaticCanvasSize = Enum.AutomaticSize.Y
diagnostics.CanvasSize = UDim2.new()
diagnostics.ScrollBarThickness = 6
diagnostics.Parent = gui
padding:Clone().Parent = diagnostics
layout:Clone().Parent = diagnostics

local order: number = 0

local function label(name: string, content: string, height: number, size: number?): TextLabel
	order += 1

	local element: TextLabel = Instance.new("TextLabel")
	element.Name = name
	element.LayoutOrder = order
	element.Size = UDim2.new(1, -8, 0, height)
	element.AutomaticSize = Enum.AutomaticSize.Y
	element.BackgroundTransparency = 1
	element.Font = Enum.Font.Gotham
	element.TextSize = size or 15
	element.TextColor3 = textColor
	element.TextXAlignment = Enum.TextXAlignment.Left
	element.TextYAlignment = Enum.TextYAlignment.Top
	element.TextWrapped = true
	element.Text = content
	element.Parent = scroll

	return element
end

label("Title", "INPUT / GESTURES", 32, 25)

label(
	"Instructions",
	"Q  /  right mouse button  /  gamepad R2  /  the touch pad below. Click the game viewport first.\nTap briefly, double tap, or keep holding through both thresholds. Scroll for live diagnostics.",
	58
)

local status: TextLabel = label("Status", "Starting the real server/client runtime...", 42, 18)
status.TextColor3 = accent

local configuration: TextLabel = label("Configuration", "", 65)
local pad: TextButton = Instance.new("TextButton")
order += 1
pad.Name = "NativeTouchPad"
pad.LayoutOrder = order
pad.Size = UDim2.new(1, -8, 0, 62)
pad.BackgroundColor3 = panel
pad.TextColor3 = accent
pad.Font = Enum.Font.GothamBold
pad.TextSize = 20
pad.TextWrapped = true
pad.Text = "PRESS / HOLD HERE"
pad.AutoButtonColor = true
pad.Parent = scroll

local inputLabel: InputActionLabel = Instance.new("InputActionLabel")
order += 1
inputLabel.Name = "NativeBindingLabel"
inputLabel.LayoutOrder = order
inputLabel.Size = UDim2.new(1, -8, 0, 34)
inputLabel.BackgroundTransparency = 1
inputLabel.Parent = scroll

local policies: { Types.DoubleTapArbitration } = { "PreferSpecific", "Independent", "DeferredTap" }
local policy: Types.DoubleTapArbitration = "PreferSpecific"
local enabled: boolean = true
local installed: boolean = true
local remapped: boolean = false
local suppress: boolean = false
local overlap: boolean = false
local started: number = os.clock()
local lines: { string } = {}
local logs: TextLabel
local candidates: TextLabel
local primitiveCount: number = 0
local gestureCount: number = 0

local function log(content: string): ()
	table.insert(lines, 1, string.format("%7.3f  %s", os.clock() - started, content))

	if #lines > 28 then
		table.remove(lines)
	end

	logs.Text = table.concat(lines, "\n")
end

local function check(success: boolean, reason: string?): boolean
	if not success then
		status.Text = "REJECTED: " .. (reason or "UnknownFailure")
		log(status.Text)
	end

	return success
end

local function refresh(): ()
	configuration.Text = string.format(
		"%s | context %s | gestures %s | keyboard %s\nTap <= %.2fs  /  Held 0.50s  /  LongHeld 1.00s  /  double gap <= 0.50s\nHold suppresses Tap: %s. Primitive events: %d  /  gesture events: %d.",
		policy,
		if enabled then "ON" else "OFF",
		if installed then "ON" else "OFF",
		if remapped then "E" else "Q",
		if overlap then 0.75 else 0.25,
		tostring(suppress),
		primitiveCount,
		gestureCount
	)
end

local function install(): ()
	if
		check(Input.SetSource("Manual.Gestures", {
			gestures = {
				Primary = {
					Tap = { maxDurationSeconds = if overlap then 0.75 else 0.25, suppressIfHoldRecognized = suppress },
					Held = { afterSeconds = 0.5 },
					LongHeld = { afterSeconds = 1 },
					DoubleTapped = {
						maxTapDurationSeconds = if overlap then 0.75 else 0.25,
						maxGapSeconds = 0.5,
						arbitration = policy,
					},
				},
			},
		}))
	then
		installed = true
	end

	refresh()
end

local function button(content: string, callback: (TextButton) -> ()): TextButton
	order += 1

	local element: TextButton = Instance.new("TextButton")
	element.Name = "Control" .. order
	element.LayoutOrder = order
	element.Size = UDim2.new(1, -8, 0, 37)
	element.BackgroundColor3 = panel
	element.TextColor3 = textColor
	element.Font = Enum.Font.GothamMedium
	element.TextSize = 14
	element.TextWrapped = true
	element.Text = content
	element.Parent = scroll

	element.Activated:Connect(function()
		callback(element)
	end)

	return element
end

for _, nextPolicy: Types.DoubleTapArbitration in policies do
	button("Policy: " .. nextPolicy, function()
		policy = nextPolicy

		if policy == "DeferredTap" then
			suppress = false
		end

		install()
		log("Policy installed: " .. policy)
	end)
end

button("Toggle context (try this while Q is held)", function()
	if check(Input.SetContextEnabled("Gameplay", not enabled)) then
		enabled = not enabled
	end

	refresh()

	log(
		"Context " .. (if enabled then "enabled; release then press again" else "disabled; expect Cancelled, never Tap")
	)
end)

button("Rebind keyboard Q / E (other device slots stay installed)", function()
	local success: boolean, reason: string?

	if remapped then
		success, reason = Input.RemoveSource("Manual.Keybinds")
	else
		success, reason = Input.SetSource(
			"Manual.Keybinds",
			{ priority = 1000, bindingOverrides = { Primary = { Keyboard = { keyCode = Enum.KeyCode.E } } } }
		)
	end

	if check(success, reason) then
		remapped = not remapped
	end

	refresh()
	log("Binding changed; a held input must rearm")
end)

button("Remove / reinstall gesture source (native input stays active)", function()
	if installed then
		if check(Input.RemoveSource("Manual.Gestures")) then
			installed = false
		end
	else
		install()
	end

	refresh()
	log("Gesture source " .. (if installed then "installed; starts on the next press" else "removed"))
end)

button("Reapply identical source (a held input and pending timers should continue)", function()
	install()
	log("Equivalent declaration reapplied")
end)

button("Toggle Tap window: short 0.25s / overlap 0.75s", function()
	overlap = not overlap
	install()
end)

button("Toggle same-source hold suppression (uses overlap window)", function()
	suppress = not suppress
	overlap = true

	if suppress and policy == "DeferredTap" then
		policy = "PreferSpecific"
	end

	install()
end)

button("Reset recognition history (preserves the physical I1 epoch)", function()
	local owner: Types.InputOwner? = State.Get()

	if owner ~= nil then
		check(owner.ResetRecognition(nil, "ManualReset"))
	end

	log("Recognition reset; no completion or fabricated release")
end)

button("Clear event log", function()
	table.clear(lines)
	logs.Text = ""
end)

local diagnosticsTitle: TextLabel = label("DiagnosticsTitle", "LIVE INPUT / RECOGNITION", 32, 21)
diagnosticsTitle.Parent = diagnostics

local expected: TextLabel = label(
	"Expected",
	"TRY: one Tap; double tap; hold past 0.5s and 1s; disable/rebind while held; remove gestures during the double gap. PreferSpecific publishes a second-release Tap but marks it ineligible; Independent keeps it eligible. DeferredTap publishes one delayed Tap or one DoubleTapped.",
	84
)

expected.Parent = diagnostics

candidates = label(
	"Candidates",
	"Private candidate order will appear here. Eligibility is independent of public recognition.",
	58
)

candidates.Parent = diagnostics
logs = label("EventLog", "", 650, 13)
logs.Parent = diagnostics
logs.Font = Enum.Font.Code
logs.TextWrapped = true

local function resize(): ()
	local activeCamera: Camera? = Workspace.CurrentCamera
	local width: number = if activeCamera ~= nil then activeCamera.ViewportSize.X else 1000

	if width < 780 then
		scroll.AnchorPoint = Vector2.new(0.5, 0)
		scroll.Position = UDim2.fromScale(0.5, 0.02)
		scroll.Size = UDim2.fromScale(0.94, 0.53)
		diagnostics.AnchorPoint = Vector2.new(0.5, 1)
		diagnostics.Position = UDim2.fromScale(0.5, 0.98)
		diagnostics.Size = UDim2.fromScale(0.94, 0.4)
	else
		scroll.AnchorPoint = Vector2.new(0, 0.5)
		scroll.Position = UDim2.fromScale(0.03, 0.5)
		scroll.Size = UDim2.fromScale(0.4, 0.92)
		diagnostics.AnchorPoint = Vector2.new(1, 0.5)
		diagnostics.Position = UDim2.fromScale(0.97, 0.5)
		diagnostics.Size = UDim2.fromScale(0.52, 0.92)
	end
end

resize()

local success: boolean, failure = Client.Init()

if not success then
	status.Text = "STARTUP FAILED: " .. (if failure ~= nil then failure.reason else "UnknownFailure")

	return
end

local camera: Camera? = Workspace.CurrentCamera

if camera ~= nil then
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(0, 8, 18)
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize)
	resize()
end

assert(
	Input.SetSource("Manual.Controls", {
		contexts = { Gameplay = { priority = 2000, sink = true } },
		inputs = {
			Primary = {
				context = "Gameplay",
				type = Enum.InputActionType.Bool,
				displayName = "Gesture test",
				bindings = {
					Keyboard = { keyCode = Enum.KeyCode.Q },
					Mouse = { keyCode = Enum.KeyCode.MouseRightButton },
					Gamepad = { keyCode = Enum.KeyCode.ButtonR2, pressedThreshold = 0.8, releasedThreshold = 0.2 },
					Touch = { uiButton = pad },
				},
			},
		},
	}),
	"ManualInputInstallationFailed"
)

assert(Input.BindActionLabel("Primary", inputLabel), "ManualLabelInstallationFailed")
install()
assert(Input.SetContextEnabled("Gameplay", true), "ManualContextEnableFailed")

Input.OnInput:Connect(function(event: Types.SemanticInputEvent)
	primitiveCount += 1
	status.Text = "INPUT: " .. event.kind
	pad.Text = if event.kind == "Pressed" then "DOWN — KEEP HOLDING TO TEST THRESHOLDS" else "PRESS / HOLD HERE"

	log(
		string.format(
			"I#%d %s%s",
			event.ordinal,
			event.kind,
			if event.kind == "Cancelled" then " / " .. event.reason else ""
		)
	)

	refresh()
end)

Input.OnGesture:Connect(function(event: Types.GestureEvent)
	gestureCount += 1
	status.Text = "GESTURE: " .. event.gesture

	local details: string

	if event.gesture == "Tap" then
		details = string.format(
			"duration %.3fs; deferred %.3fs",
			event.pressDurationSeconds,
			event.timestamp - event.recognizedAt
		)
	elseif event.gesture == "DoubleTapped" then
		details = string.format("gap %.3fs", event.gapSeconds)
	else
		details = string.format("threshold %.2fs; elapsed %.3fs", event.thresholdSeconds, event.elapsedSeconds)
	end

	log(string.format("G#%d %s <- I#%d / %s", event.ordinal, event.gesture, event.triggerInputOrdinal, details))
	refresh()
end)

local owner: Types.InputOwner = assert(State.Get(), "MissingManualInputOwner")

owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
	local keys: { string } = {}

	for _, candidate: Types.GestureCandidate in group.candidates do
		table.insert(keys, candidate.key .. (if candidate.routeEligible then " [eligible]" else " [ineligible]"))
	end

	candidates.Text = string.format(
		"I#%d  %s\n%s",
		group.triggerInputOrdinal,
		group.policy or "ordinary",
		if #keys > 0 then table.concat(keys, "  >  ") else "Lifecycle only; no new-start candidates"
	)
end)

status.Text = "READY — press Q or use the pad"
refresh()
log("Real IAS bindings active. No Actions are dispatched by this fixture.")
