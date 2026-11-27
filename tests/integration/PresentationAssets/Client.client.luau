--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local KRF = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF"))
local control: RemoteEvent = ReplicatedStorage:WaitForChild("AssetsControl") :: RemoteEvent

local IDLE: string = "rbxassetid://507766388"
local NOT_A_SOUND: string = "rbxassetid://1"
local PING: string = "rbxasset://sounds/electronicpingshort.wav"
local SPARKLES: string = "rbxasset://textures/particles/sparkles_main.dds"
local BEAM: string = "rbxassetid://11"
local TRAIL: string = "rbxassetid://12"
local UNSELECTED: string = "rbxassetid://14"
local DECAL: string = "rbxassetid://21"
local MESH_TEXTURE: string = "rbxassetid://22"
local SPECIAL_MESH: string = "rbxassetid://23"
local SPECIAL_TEXTURE: string = "rbxassetid://24"
local IMAGE: string = "rbxassetid://25"
local SKY: string = "rbxassetid://26"

type Templates = {
	fireball: Folder,
	emitter: ParticleEmitter,
	unselected: Folder,
	oversized: Folder,
	descendants: number,
}

local function check(condition: boolean, message: string): ()
	if not condition then
		error(message, 2)
	end
end

local function waitFor(predicate: () -> boolean, seconds: number, message: string): ()
	local deadline: number = os.clock() + seconds

	while not predicate() do
		check(os.clock() < deadline, message)
		task.wait()
	end
end

local function templates(): Templates
	local root: Folder = Instance.new("Folder")
	root.Name = "PreloadTemplates"

	local fireball: Folder = Instance.new("Folder")
	fireball.Name = "Fireball"
	fireball.Parent = root

	local sound: Sound = Instance.new("Sound")
	sound.SoundId = PING
	sound.Parent = fireball

	local model: Model = Instance.new("Model")
	model.Parent = fireball

	local part: Part = Instance.new("Part")
	part.Parent = model

	local emitter: ParticleEmitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLES
	emitter.Enabled = false
	emitter.Parent = part

	local from: Attachment = Instance.new("Attachment")
	from.Parent = part

	local to: Attachment = Instance.new("Attachment")
	to.Parent = part

	local beam: Beam = Instance.new("Beam")
	beam.Texture = BEAM
	beam.Attachment0 = from
	beam.Attachment1 = to
	beam.Parent = part

	local trail: Trail = Instance.new("Trail")
	trail.Texture = TRAIL
	trail.Attachment0 = from
	trail.Attachment1 = to
	trail.Parent = part

	local decal: Decal = Instance.new("Decal")
	decal.Texture = DECAL
	decal.Parent = part

	local meshPart: MeshPart = Instance.new("MeshPart")
	meshPart.TextureID = MESH_TEXTURE
	meshPart.Parent = model

	local specialMesh: SpecialMesh = Instance.new("SpecialMesh")
	specialMesh.MeshId = SPECIAL_MESH
	specialMesh.TextureId = SPECIAL_TEXTURE
	specialMesh.Parent = part

	local image: ImageLabel = Instance.new("ImageLabel")
	image.Image = IMAGE
	image.Parent = fireball

	local sky: Sky = Instance.new("Sky")
	sky.SkyboxBk = SKY
	sky.Parent = fireball

	Instance.new("Script").Parent = fireball
	Instance.new("StringValue").Parent = model

	local unselected: Folder = Instance.new("Folder")
	unselected.Name = "Unselected"
	unselected.Parent = root

	local stray: Sound = Instance.new("Sound")
	stray.SoundId = UNSELECTED
	stray.Parent = unselected

	local oversized: Folder = Instance.new("Folder")
	oversized.Name = "Oversized"
	oversized.Parent = root

	for _ = 1, 2100 do
		Instance.new("Folder").Parent = oversized
	end

	root.Parent = ReplicatedStorage

	return {
		fireball = fireball,
		emitter = emitter,
		unselected = unselected,
		oversized = oversized,
		descendants = #fireball:GetDescendants(),
	}
end

local function character(): Model
	local player: Player = Players.LocalPlayer
	local model: Model = player.Character or player.CharacterAdded:Wait()

	model:WaitForChild("Humanoid"):WaitForChild("Animator")

	waitFor(function(): boolean
		return model:IsDescendantOf(Workspace)
	end, 10, "Character never reached Workspace")

	return model
end

local function run(): string
	check(not KRF.Client._IsInitialized(), "Client.Init ran before the fixture")

	local selected: Templates = templates()
	local rig: Model = character()
	local reports: { [string]: KRF.PreloadReport } = {}
	local casts: number = 0

	local function collect(name: string): (KRF.PreloadReport) -> ()
		return function(report: KRF.PreloadReport): ()
			check(reports[name] == nil, `{name} completed twice`)
			reports[name] = report
		end
	end

	local accepted: boolean = false
	local refusal: string? = nil

	local caller: thread = coroutine.create(function(): ()
		accepted, refusal = KRF.Assets.Preload({
			{ kind = "Animation", assetId = IDLE },
			{ kind = "Sound", assetId = NOT_A_SOUND },
			selected.fireball,
			selected.emitter,
		}, collect("Encounter"))
	end)

	coroutine.resume(caller)

	check(coroutine.status(caller) == "dead", "Preload yielded its caller")
	check(accepted, `Encounter preload refused: {tostring(refusal)}`)
	check(KRF.Assets.Preload({ selected.oversized }, collect("Oversized")), "Oversized preload refused")

	for index = 1, 6 do
		check(
			KRF.Assets.Preload({ { kind = "Animation", assetId = IDLE } }, collect(`Fill{index}`)),
			"Fill preload refused"
		)
	end

	local busy: boolean, busyReason: string? = KRF.Assets.Preload({ selected.fireball })

	check(not busy and busyReason == "PreloadBusy", "A ninth preload was not refused as busy")

	local playback: KRF.AnimationPlayback? = KRF.Animations.Play(rig, IDLE)

	check(playback ~= nil, "Animations.Play waited on or failed beside a pending preload")
	check(next(reports) == nil, "A preload settled on the caller's stack")

	local initialized, failure = KRF.Client.Init({
		presentations = {
			{
				id = "Cast.Highlight",
				entry = { event = KRF.PresentationEvents.Action.Started, id = "Cast" },
				create = function(ctx: KRF.PresentationContext): ()
					casts += 1
					ctx:Finish()
				end,
			},
		},
	})

	check(initialized, if failure ~= nil then failure.reason else "Client.Init failed")

	control:FireServer("Cast")

	waitFor(function(): boolean
		return casts > 0
	end, 30, "The Cast Presentation never started beside pending preloads")

	waitFor(function(): boolean
		local count: number = 0

		for _ in reports do
			count += 1
		end

		return count == 8
	end, 60, "Not every accepted preload completed")

	local encounter: KRF.PreloadReport = reports.Encounter

	check(encounter.error == nil, `Encounter error: {tostring(encounter.error)}`)
	check(table.isfrozen(encounter.statuses :: any), "Encounter statuses are writable")
	check(encounter.statuses[IDLE] == Enum.AssetFetchStatus.Success, "The idle animation was not fetched")
	check(encounter.statuses[PING] == Enum.AssetFetchStatus.Success, "The template Sound was not fetched")
	check(encounter.statuses[SPARKLES] == Enum.AssetFetchStatus.Success, "The emitter texture was not fetched")
	check(encounter.statuses[BEAM] == Enum.AssetFetchStatus.Failure, "The Beam texture was not reported as failed")
	check(encounter.statuses[TRAIL] == Enum.AssetFetchStatus.Failure, "The Trail texture was not reported as failed")

	for _, contentId: string in { DECAL, MESH_TEXTURE, SPECIAL_MESH, SPECIAL_TEXTURE, IMAGE, SKY } do
		check(encounter.statuses[contentId] == Enum.AssetFetchStatus.Failure, `{contentId} was not reported as failed`)
	end

	check(
		encounter.statuses[NOT_A_SOUND] == Enum.AssetFetchStatus.Success,
		"A fetched asset of the wrong type no longer reports Success"
	)

	check(encounter.statuses[UNSELECTED] == nil, "An unselected sibling's content was fetched")
	check(selected.emitter.Parent ~= nil and selected.emitter.Texture == SPARKLES, "The emitter was changed")
	check(#selected.fireball:GetDescendants() == selected.descendants, "The selected template was changed")
	check(#selected.unselected:GetChildren() == 1, "The unselected template was changed")
	check(reports.Oversized.error == "PreloadDescendantLimit", "The oversized selection was not refused")

	for contentId: string in reports.Oversized.statuses do
		error(`The oversized selection reported {contentId}`)
	end

	for index = 1, 6 do
		check(reports[`Fill{index}`].statuses[IDLE] == Enum.AssetFetchStatus.Success, "A repeat preload failed")
	end

	if playback ~= nil then
		playback:Destroy()
	end

	local abandoned: LocalScript = (ReplicatedStorage:WaitForChild("AbandonedPreload") :: LocalScript):Clone()
	local player: Player = Players.LocalPlayer

	abandoned.Parent = player:WaitForChild("PlayerScripts")

	waitFor(function(): boolean
		return player:GetAttribute("AbandonedPreloadAccepted") ~= nil
	end, 10, "The abandoned preload script never ran")

	check(player:GetAttribute("AbandonedPreloadAccepted") == true, "The abandoned preload was refused")
	task.wait(2)

	check(player:GetAttribute("AbandonedPreloadCompleted") == true, "A destroyed caller's preload never completed")

	for index = 1, 8 do
		local refilled: boolean, refillReason: string? = KRF.Assets.Preload({ selected.emitter })

		check(refilled, `Refill {index} was refused after its caller was destroyed: {tostring(refillReason)}`)
	end

	local observed: { string } = {}

	for contentId: string, status: Enum.AssetFetchStatus in encounter.statuses do
		table.insert(observed, `{contentId}={status.Name}`)
	end

	table.sort(observed)

	return table.concat(observed, " ")
end

local succeeded: boolean, outcome: unknown = pcall(run)

control:FireServer(if succeeded then "Pass" else "Fail", tostring(outcome))
