--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local Workspace = game:GetService("Workspace")

local report: RemoteEvent = ReplicatedStorage:WaitForChild("AnimationsReport") :: RemoteEvent
local CLIENT_COUNT: number = 2

local function rig(name: string, controllerClass: string, withAnimator: boolean, position: Vector3): Model
	local model: Model =
		Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)

	model.Name = name

	local animate: Instance? = model:FindFirstChild("Animate")
	local humanoid: Humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root: BasePart = model:FindFirstChild("HumanoidRootPart") :: BasePart

	if animate ~= nil then
		animate:Destroy()
	end

	for _, child: Instance in humanoid:GetChildren() do
		if child:IsA("Animator") then
			child:Destroy()
		end
	end

	local controller: Instance = humanoid

	if controllerClass == "AnimationController" then
		humanoid:Destroy()
		controller = Instance.new("AnimationController")
		controller.Parent = model
	end

	if withAnimator then
		Instance.new("Animator").Parent = controller
	end

	root.Anchored = true
	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace

	return model
end

local baseplate: Part = Instance.new("Part")
baseplate.Name = "Baseplate"
baseplate.Anchored = true
baseplate.Size = Vector3.new(512, 4, 512)
baseplate.Position = Vector3.new(0, -2, 0)
baseplate.Parent = Workspace

rig("Dummy", "Humanoid", false, Vector3.new(20, 5, 0))
rig("Prop", "AnimationController", true, Vector3.new(-20, 5, 0))

local passed: { [Player]: boolean } = {}
local finished: boolean = false

local function finish(success: boolean, detail: string?): ()
	if finished then
		return
	end

	finished = true
	StudioTestService:EndTest({ success = success, reason = detail })
end

report.OnServerEvent:Connect(function(player: Player, outcome: unknown, detail: unknown)
	if outcome ~= "Pass" then
		finish(false, `{player.Name}: {tostring(detail)}`)

		return
	end

	passed[player] = true

	local count: number = 0

	for _ in passed do
		count += 1
	end

	if count >= CLIENT_COUNT then
		finish(true, nil)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	if not passed[player] then
		finish(false, `{player.Name} left before reporting`)
	end
end)

task.delay(100, function()
	finish(false, "Animations native fixture timed out")
end)
