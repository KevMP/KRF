--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Presentation.types)
local AnimationTrackCache = require(KRF.client.Presentation.utils.AnimationTrackCache)
local AnimationPlayer = require(KRF.client.Presentation.utils.AnimationPlayer)

export type PlayCall = {
	read fadeTime: number?,
	read weight: number?,
	read speed: number?,
	read timePosition: number,
}

export type FakeTrack = {
	animationId: string,
	animator: Animator,
	animation: Animation,
	IsPlaying: boolean,
	fading: boolean,
	Priority: Enum.AnimationPriority,
	Looped: boolean,
	TimePosition: number,
	Length: number,
	plays: { PlayCall },
	stops: { number? },
	speeds: { number },
	weights: { { weight: number, fadeTime: number? } },
	destroyed: boolean,
	failPlay: boolean,
	Play: (self: FakeTrack, fadeTime: number?, weight: number?, speed: number?) -> (),
	Stop: (self: FakeTrack, fadeTime: number?) -> (),
	AdjustSpeed: (self: FakeTrack, speed: number) -> (),
	AdjustWeight: (self: FakeTrack, weight: number, fadeTime: number?) -> (),
	Destroy: (self: FakeTrack) -> (),
}

export type Harness = {
	animations: Types.AnimationsModule,
	cache: Types.AnimationTrackCache,
	loads: { FakeTrack },
	attempts: { Animation },
	foreign: { [Animator]: { FakeTrack } },
	failLoad: boolean,
	failNewPlays: boolean,
	failPlayingQuery: boolean,
}

local TestUtils = {}
local models: { Model } = {}

local function play(self: FakeTrack, fadeTime: number?, weight: number?, speed: number?): ()
	if self.failPlay or self.destroyed then
		error("AnimationTrack cannot play")
	end

	table.insert(self.plays, {
		fadeTime = fadeTime,
		weight = weight,
		speed = speed,
		timePosition = self.TimePosition,
	})

	self.IsPlaying = true
	self.fading = false
end

local function stop(self: FakeTrack, fadeTime: number?): ()
	table.insert(self.stops, fadeTime)
	self.fading = self.IsPlaying and (fadeTime == nil or fadeTime > 0)
	self.IsPlaying = false
end

local function adjustSpeed(self: FakeTrack, speed: number): ()
	table.insert(self.speeds, speed)
end

local function adjustWeight(self: FakeTrack, weight: number, fadeTime: number?): ()
	table.insert(self.weights, { weight = weight, fadeTime = fadeTime })
end

local function destroy(self: FakeTrack): ()
	self.destroyed = true
	self.IsPlaying = false
	self.fading = false
end

function TestUtils.Track(animator: Animator, animation: Animation): FakeTrack
	return {
		animationId = animation.AnimationId,
		animator = animator,
		animation = animation,
		IsPlaying = false,
		fading = false,
		Priority = Enum.AnimationPriority.Core,
		Looped = true,
		TimePosition = 0,
		Length = 0,
		plays = {},
		stops = {},
		speeds = {},
		weights = {},
		destroyed = false,
		failPlay = false,
		Play = play,
		Stop = stop,
		AdjustSpeed = adjustSpeed,
		AdjustWeight = adjustWeight,
		Destroy = destroy,
	}
end

function TestUtils.Harness(): Harness
	local harness: Harness

	local port: Types.AnimationTrackPort = {
		Load = function(animator: Animator, animation: Animation): AnimationTrack
			table.insert(harness.attempts, animation)

			if harness.failLoad then
				error("LoadAnimation failed")
			end

			local track: FakeTrack = TestUtils.Track(animator, animation)
			track.failPlay = harness.failNewPlays
			table.insert(harness.loads, track)

			return (track :: any) :: AnimationTrack
		end,
		GetPlayingTracks = function(animator: Animator): { AnimationTrack }
			if harness.failPlayingQuery then
				error("GetPlayingAnimationTracks failed")
			end

			local playing: { AnimationTrack } = {}
			local foreign: { FakeTrack } = harness.foreign[animator] or {}

			for _, track: FakeTrack in harness.loads do
				if track.animator == animator and (track.IsPlaying or track.fading) then
					table.insert(playing, (track :: any) :: AnimationTrack)
				end
			end

			for _, track: FakeTrack in foreign do
				table.insert(playing, (track :: any) :: AnimationTrack)
			end

			return playing
		end,
	}

	local cache: Types.AnimationTrackCache = AnimationTrackCache.new(port)

	harness = {
		animations = AnimationPlayer.new(cache),
		cache = cache,
		loads = {},
		attempts = {},
		foreign = {},
		failLoad = false,
		failNewPlays = false,
		failPlayingQuery = false,
	}

	return harness
end

function TestUtils.Rig(
	controllerClass: "Humanoid" | "AnimationController",
	withAnimator: boolean
): (Model, Instance, Animator?)
	local model: Model = Instance.new("Model")
	model.Name = "AnimationRig"

	local controller: Instance = Instance.new(controllerClass)
	controller.Parent = model

	local animator: Animator? = nil

	if withAnimator then
		local created: Animator = Instance.new("Animator")
		created.Parent = controller
		animator = created
	end

	model.Parent = Workspace
	table.insert(models, model)

	return model, controller, animator
end

function TestUtils.Animator(controller: Instance): Animator
	return controller:FindFirstChildOfClass("Animator") :: Animator
end

function TestUtils.IsDestroyed(instance: Instance): boolean
	local parent: Instance? = instance.Parent
	local probe: Folder = Instance.new("Folder")

	local movable: boolean = pcall(function(): ()
		instance.Parent = probe
		instance.Parent = parent
	end)

	probe:Destroy()

	return not movable
end

function TestUtils.Cleanup(): ()
	for _, model: Model in models do
		model:Destroy()
	end

	table.clear(models)
end

return TestUtils
