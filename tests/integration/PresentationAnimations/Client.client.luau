--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local KRF = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF"))
local Client = require(ReplicatedStorage.Packages.KRF.client)
local report: RemoteEvent = ReplicatedStorage:WaitForChild("AnimationsReport") :: RemoteEvent

local IDLE: string = "rbxassetid://507766388"
local NOT_AN_ANIMATION: string = "rbxassetid://1"

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

local function play(model: Model, animationId: string, options: KRF.AnimationPlayOptions?): KRF.AnimationPlayback
	local playback: KRF.AnimationPlayback?, reason: string? = KRF.Animations.Play(model, animationId, options)

	check(playback ~= nil, `Play failed on {model.Name}: {tostring(reason)}`)

	return playback :: KRF.AnimationPlayback
end

local function advances(track: AnimationTrack, seconds: number): boolean
	local deadline: number = os.clock() + seconds

	while track.TimePosition <= 0 and os.clock() < deadline do
		task.wait()
	end

	return track.TimePosition > 0
end

local function countAnimators(controller: Instance): number
	local count: number = 0

	for _, child: Instance in controller:GetChildren() do
		if child:IsA("Animator") then
			count += 1
		end
	end

	return count
end

local function character(): ()
	local player: Player = Players.LocalPlayer
	local model: Model = player.Character or player.CharacterAdded:Wait()
	local humanoid: Humanoid = model:WaitForChild("Humanoid") :: Humanoid
	local animator: Animator = humanoid:WaitForChild("Animator") :: Animator

	waitFor(function(): boolean
		return model:IsDescendantOf(Workspace)
	end, 10, "Character never reached Workspace")

	local animate: Instance? = model:WaitForChild("Animate", 10)
	local animateDescendants: number = if animate ~= nil then #animate:GetDescendants() else 0
	local foreign: { [AnimationTrack]: boolean } = {}

	for _, playing: AnimationTrack in animator:GetPlayingAnimationTracks() do
		foreign[playing] = true
	end

	local first: KRF.AnimationPlayback = play(model, IDLE, { fadeTime = 0 })
	local track: AnimationTrack = first:GetTrack() :: AnimationTrack

	check(countAnimators(humanoid) == 1, "Created a second Animator beside the character's own")
	check(not foreign[track], "Adopted a track the character's Animate script loaded")

	waitFor(function(): boolean
		return track.Length > 0
	end, 15, "The Roblox-owned idle animation never loaded")

	task.wait()

	check(not track.Looped, "Loading the looped idle asset overrode looped = false")

	check(
		track.Priority == Enum.AnimationPriority.Action,
		`Loading the asset overrode the default priority: {track.Priority}`
	)

	waitFor(function(): boolean
		return track.TimePosition > 0.3
	end, 10, "Playback never advanced")

	local position: number = track.TimePosition
	local second: KRF.AnimationPlayback = play(model, IDLE, { fadeTime = 0 })
	task.wait()

	check(second:GetTrack() == track, "A second Play loaded another track")
	check(track.TimePosition < position, `A second Play did not restart: {track.TimePosition} after {position}`)
	check(first:GetTrack() == nil, "The replaced handle still exposes the track")

	first:Stop(0)
	first:Destroy()
	task.wait()
	check(track.IsPlaying, "The replaced handle stopped the newer playback")

	local weightAtStopped: number? = nil
	local weightAtEnded: number? = nil

	local stopped: RBXScriptConnection = track.Stopped:Connect(function(): ()
		weightAtStopped = weightAtStopped or track.WeightCurrent
	end)

	local ended: RBXScriptConnection = track.Ended:Connect(function(): ()
		if weightAtStopped ~= nil then
			weightAtEnded = weightAtEnded or track.WeightCurrent
		end
	end)

	second:Stop(0.5)

	check(not track.IsPlaying, "Stop left the track playing")

	check(
		table.find(animator:GetPlayingAnimationTracks(), track) ~= nil,
		"A fading track was missing from GetPlayingAnimationTracks"
	)

	waitFor(function(): boolean
		return weightAtEnded ~= nil
	end, 10, "Ended never fired after Stopped")

	stopped:Disconnect()
	ended:Disconnect()

	check(
		(weightAtStopped :: number) > (weightAtEnded :: number),
		`Stopped fired after the fade: weight {weightAtStopped} at Stopped, {weightAtEnded} at Ended`
	)

	local fading: KRF.AnimationPlayback = play(model, IDLE, { fadeTime = 0 })

	waitFor(function(): boolean
		return track.TimePosition > 0.2
	end, 10, "The fading playback never advanced")

	fading:Stop(0.5)
	task.wait()

	check(table.find(animator:GetPlayingAnimationTracks(), track) ~= nil, "The track was not fading before the replay")

	local replay: KRF.AnimationPlayback = play(model, IDLE, { fadeTime = 0.1 })
	local resumeAt: number = time() + 1

	waitFor(function(): boolean
		return time() >= resumeAt
	end, 20, "Simulation time stalled")

	check(replay:GetTrack() == track, "A replay during the fade used another track or was retired")
	check(track.IsPlaying, "The earlier fade's end stopped the replay")
	check(fading:GetTrack() == nil, "The faded handle stayed current after the replay")

	replay:Destroy()
	task.wait(0.2)

	local quick: KRF.AnimationPlayback = play(model, IDLE, { fadeTime = 0, speed = 4 })

	waitFor(function(): boolean
		return not track.IsPlaying
	end, 15, "A non-looped playback never ended naturally")

	check(quick:GetTrack() == track, "A natural end retired the current handle")
	check(not track.Looped, "The default playback looped")

	quick:Destroy()

	check(
		animate == nil or #animate:GetDescendants() == animateDescendants,
		"The Animate script's Animations were changed"
	)
end

local function dummy(): ()
	local model: Model = Workspace:WaitForChild("Dummy") :: Model
	local humanoid: Humanoid = model:WaitForChild("Humanoid") :: Humanoid

	check(humanoid:FindFirstChildOfClass("Animator") == nil, "The dummy arrived with an Animator")

	local playback: KRF.AnimationPlayback = play(model, IDLE)
	local animator: Animator? = humanoid:FindFirstChildOfClass("Animator")
	local track: AnimationTrack = playback:GetTrack() :: AnimationTrack

	check(animator ~= nil, "No Animator was created for the dummy")

	check(advances(track, 10), "The dummy's created Animator never advanced")

	check(
		table.find((animator :: Animator):GetPlayingAnimationTracks(), track) ~= nil,
		"The dummy's track plays on another Animator"
	)

	local outside: Model = model:Clone()
	outside.Parent = ReplicatedStorage

	local refused: KRF.AnimationPlayback?, reason: string? = KRF.Animations.Play(outside, IDLE)

	check(refused == nil and reason == "AnimationModelNotInWorld", `Outside a WorldRoot: {tostring(reason)}`)
	check(outside.Parent == ReplicatedStorage, "The Model was reparented")

	local viewport: ViewportFrame = Instance.new("ViewportFrame")

	local world: WorldModel = Instance.new("WorldModel")
	world.Parent = viewport
	outside.Parent = world
	viewport.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local preview: KRF.AnimationPlayback = play(outside, IDLE)
	local previewTrack: AnimationTrack = preview:GetTrack() :: AnimationTrack

	check(advances(previewTrack, 10), "The WorldModel preview never advanced")

	check(previewTrack ~= track, "The preview shared the dummy's track")

	viewport:Destroy()

	check(preview:GetTrack() == nil, "Destroying the preview left its handle current")

	humanoid.Parent = nil

	local replacement: Humanoid = Instance.new("Humanoid")
	replacement.Parent = model

	check(playback:GetTrack() == nil, "A removed Humanoid's handle stayed current")

	local respawned: KRF.AnimationPlayback = play(model, IDLE)
	local respawnedTrack: AnimationTrack = respawned:GetTrack() :: AnimationTrack

	check(respawnedTrack ~= track, "A replaced Humanoid reused the old track")

	check(
		table.find(
			(replacement:FindFirstChildOfClass("Animator") :: Animator):GetPlayingAnimationTracks(),
			respawnedTrack
		) ~= nil,
		"The replacement Humanoid's track plays elsewhere"
	)

	respawned:Destroy()
	humanoid:Destroy()
end

local function prop(): ()
	local model: Model = Workspace:WaitForChild("Prop") :: Model
	local controller: AnimationController = model:WaitForChild("AnimationController") :: AnimationController
	local animator: Animator = controller:WaitForChild("Animator") :: Animator

	local first: KRF.AnimationPlayback = play(model, IDLE)
	local track: AnimationTrack = first:GetTrack() :: AnimationTrack

	animator:Destroy()

	check(first:GetTrack() == nil, "A destroyed Animator's handle stayed current")

	local replacement: KRF.AnimationPlayback = play(model, IDLE)

	check(replacement:GetTrack() ~= track, "A replaced Animator reused an old track")

	check(advances(replacement:GetTrack() :: AnimationTrack, 10), "The prop's replacement Animator never advanced")
	check(countAnimators(controller) == 1, "Expected exactly one replacement Animator")

	replacement:Destroy()

	local silent: KRF.AnimationPlayback = play(model, NOT_AN_ANIMATION)
	local silentTrack: AnimationTrack = silent:GetTrack() :: AnimationTrack
	task.wait(1)

	check(silentTrack.Length == 0, "A non-animation asset reported a length")

	silent:Destroy()
end

local succeeded: boolean, failure: unknown = pcall(function(): ()
	check(not Client._IsInitialized(), "Client.Init ran in the standalone fixture")

	character()
	dummy()
	prop()

	check(not Client._IsInitialized(), "Animations started Client.Init")
end)

report:FireServer(if succeeded then "Pass" else "Fail", if succeeded then nil else tostring(failure))
