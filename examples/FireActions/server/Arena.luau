--!strict
local Arena = {}

local function block(name: string, size: Vector3, position: Vector3, parent: Instance): Part
	local part: Part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.Position = position
	part.Color = Color3.fromRGB(100, 100, 100)
	part.Parent = parent

	return part
end

function Arena.Build(): (Model, Folder)
	local floor: Part = block("ArenaFloor", Vector3.new(100, 1, 100), Vector3.new(0, -0.5, 0), workspace)
	floor.Color = Color3.fromRGB(75, 85, 75)

	local spawn: SpawnLocation = Instance.new("SpawnLocation")
	spawn.Name = "DemoSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 0.5, 12)
	spawn.Parent = workspace

	local dummy: Model = Instance.new("Model")
	dummy.Name = "TrainingDummy"

	local body: Part = block("HumanoidRootPart", Vector3.new(4, 6, 3), Vector3.new(0, 3, -12), dummy)
	block("Head", Vector3.new(3, 2, 3), Vector3.new(0, 7, -12), dummy)
	dummy.PrimaryPart = body
	dummy.Parent = workspace

	local effects: Folder = Instance.new("Folder")
	effects.Name = "FireDemoEffects"
	effects.Parent = workspace

	return dummy, effects
end

return Arena
