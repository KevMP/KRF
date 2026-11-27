--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local TestUtils = require(script.Parent.Utils.AnimationTestUtils)

local TRACK_LIMIT: number = 32

afterEach(function()
	TestUtils.Cleanup()
end)

local function fill(harness: TestUtils.Harness, model: Model, count: number): { Types.AnimationPlayback }
	local playbacks: { Types.AnimationPlayback } = {}

	for index = 1, count do
		local playback: Types.AnimationPlayback? = harness.animations.Play(model, `rbxassetid://{index}`)
		table.insert(playbacks, playback :: Types.AnimationPlayback)
	end

	return playbacks
end

it("loads once per Animator and animation ID across sequential and rapid Plays", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	local first: Types.AnimationPlayback = assert(harness.animations.Play(model, "rbxassetid://1"))
	first:Stop()

	for _ = 1, 5 do
		harness.animations.Play(model, "rbxassetid://1")
	end

	local animators: number = harness.cache:_CountForTests()

	expect(#harness.loads).toBe(1)
	expect(#harness.loads[1].plays).toBe(6)
	expect(animators).toBe(1)
end)

it("never shares a track between Animators or between animation IDs", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local firstModel: Model = TestUtils.Rig("Humanoid", true)
	local secondModel: Model = TestUtils.Rig("AnimationController", true)

	local first: Types.AnimationPlayback? = harness.animations.Play(firstModel, "rbxassetid://1")
	local second: Types.AnimationPlayback? = harness.animations.Play(secondModel, "rbxassetid://1")
	local third: Types.AnimationPlayback? = harness.animations.Play(firstModel, "rbxassetid://2")

	local animators: number, tracks: number = harness.cache:_CountForTests()

	expect(#harness.loads).toBe(3)
	expect((first :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[1])
	expect((second :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[2])
	expect((third :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[3])
	expect(animators).toBe(2)
	expect(tracks).toBe(3)
end)

it("evicts the least recently used idle track when the per-Animator limit is reached", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playbacks: { Types.AnimationPlayback } = fill(harness, model, TRACK_LIMIT)

	for _, playback: Types.AnimationPlayback in playbacks do
		playback:Stop(0)
	end

	harness.animations.Play(model, "rbxassetid://1")
	harness.loads[1]:Stop(0)

	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, `rbxassetid://{TRACK_LIMIT + 1}`)

	local _animators: number, tracks: number = harness.cache:_CountForTests()

	expect(reason).toBeNil()
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[TRACK_LIMIT + 1])
	expect(harness.loads[1].destroyed).toBe(false)
	expect(harness.loads[2].destroyed).toBe(true)
	expect(TestUtils.IsDestroyed(harness.loads[2].animation)).toBe(true)
	expect(harness.loads[3].destroyed).toBe(false)
	expect(tracks).toBe(TRACK_LIMIT)
	expect(playbacks[2]:GetTrack()).toBeNil()
end)

it("never evicts a track that is still fading after Stop", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playbacks: { Types.AnimationPlayback } = fill(harness, model, TRACK_LIMIT)

	playbacks[1]:Stop(0.3)

	for index = 2, TRACK_LIMIT do
		playbacks[index]:Stop(0)
	end

	harness.animations.Play(model, `rbxassetid://{TRACK_LIMIT + 1}`)

	expect(harness.loads[1].IsPlaying).toBe(false)
	expect(harness.loads[1].fading).toBe(true)
	expect(harness.loads[1].destroyed).toBe(false)
	expect(harness.loads[2].destroyed).toBe(true)
end)

it("fails only the new animation when every cached track is busy", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playbacks: { Types.AnimationPlayback } = fill(harness, model, TRACK_LIMIT)

	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, `rbxassetid://{TRACK_LIMIT + 1}`)

	local replay: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://5")
	local replayTrack: AnimationTrack? = (replay :: Types.AnimationPlayback):GetTrack()

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationCacheFull")
	expect(#harness.loads).toBe(TRACK_LIMIT)
	expect(#harness.attempts).toBe(TRACK_LIMIT)
	expect(playbacks[1]:GetTrack()).toBe(harness.loads[1])
	expect(harness.loads[1].IsPlaying).toBe(true)
	expect(replayTrack).toBe(harness.loads[5])

	for _, track: TestUtils.FakeTrack in harness.loads do
		expect(track.destroyed).toBe(false)
	end
end)

it("keeps every cached track when the playing-track query fails at the limit", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playbacks: { Types.AnimationPlayback } = fill(harness, model, TRACK_LIMIT)

	for _, playback: Types.AnimationPlayback in playbacks do
		playback:Stop(0)
	end

	harness.failPlayingQuery = true

	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, `rbxassetid://{TRACK_LIMIT + 1}`)

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationCacheFull")
	expect(#harness.loads).toBe(TRACK_LIMIT)

	for _, track: TestUtils.FakeTrack in harness.loads do
		expect(track.destroyed).toBe(false)
	end
end)

it("releases every owned track when the Animator is destroyed", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")
	harness.animations.Play(model, "rbxassetid://2")

	local rigAnimator: Animator = animator :: Animator
	rigAnimator:Destroy()

	expect(harness.loads[1].destroyed).toBe(true)
	expect(harness.loads[2].destroyed).toBe(true)
	expect(TestUtils.IsDestroyed(harness.loads[1].animation)).toBe(true)
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBeNil()
	expect(harness.cache:Holds(rigAnimator)).toBe(false)

	harness.animations.Play(model, "rbxassetid://1")

	expect(#harness.loads).toBe(3)
	expect(harness.loads[3].animator.Parent).toBe(controller)
	expect(harness.loads[3].animator).never.toBe(animator)
end)

it("does not reuse old tracks after the Humanoid is replaced", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")

	controller.Parent = nil

	local replacement: Humanoid = Instance.new("Humanoid")
	replacement.Parent = model

	harness.animations.Play(model, "rbxassetid://1")

	expect(harness.loads[1].destroyed).toBe(true)
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBeNil()
	expect(#harness.loads).toBe(2)
	expect(harness.loads[2].animator.Parent).toBe(replacement)
	expect(harness.cache:Holds(harness.loads[1].animator)).toBe(false)
	expect(harness.cache:Holds(harness.loads[2].animator)).toBe(true)
	expect(TestUtils.IsDestroyed(controller)).toBe(false)

	controller:Destroy()
end)

it("releases tracks when the Animator is moved out of its controller", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, _controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local rigAnimator: Animator = animator :: Animator
	local destroyed: boolean = false

	local connection: RBXScriptConnection = rigAnimator.Destroying:Connect(function(): ()
		destroyed = true
	end)

	harness.animations.Play(model, "rbxassetid://1")
	rigAnimator.Parent = nil

	expect(harness.loads[1].destroyed).toBe(true)
	expect(harness.cache:Holds(rigAnimator)).toBe(false)
	expect(destroyed).toBe(false)

	connection:Disconnect()
	rigAnimator:Destroy()
end)

it("releases tracks when the Animator moves to another controller inside Workspace", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, _controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local _otherModel: Model, otherController: Instance = TestUtils.Rig("Humanoid", false)
	local rigAnimator: Animator = animator :: Animator
	harness.animations.Play(model, "rbxassetid://1")

	rigAnimator.Parent = otherController

	expect(harness.loads[1].destroyed).toBe(true)
	expect(harness.cache:Holds(rigAnimator)).toBe(false)
	expect(rigAnimator.Parent).toBe(otherController)
end)

it("releases tracks when the Humanoid moves into another Model inside Workspace", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local otherModel: Model = TestUtils.Rig("AnimationController", false)
	harness.animations.Play(model, "rbxassetid://1")

	controller.Parent = otherModel

	expect(harness.loads[1].destroyed).toBe(true)
	expect(harness.cache:Holds(animator :: Animator)).toBe(false)
	expect((animator :: Animator).Parent).toBe(controller)
end)

it("keeps tracks while the Model moves elsewhere in the DataModel", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")

	model.Parent = ReplicatedStorage
	model.Parent = Workspace

	harness.animations.Play(model, "rbxassetid://1")

	expect(#harness.loads).toBe(1)
	expect(harness.loads[1].destroyed).toBe(false)
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBeNil()
	expect(harness.cache:Holds(harness.loads[1].animator)).toBe(true)
end)

it("releases tracks when the Model leaves the DataModel without destroying the Animator", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local rigAnimator: Animator = animator :: Animator
	local destroyed: boolean = false

	local connection: RBXScriptConnection = rigAnimator.Destroying:Connect(function(): ()
		destroyed = true
	end)

	harness.animations.Play(model, "rbxassetid://1")
	model.Parent = nil

	expect(harness.loads[1].destroyed).toBe(true)
	expect(harness.cache:Holds(rigAnimator)).toBe(false)
	expect(destroyed).toBe(false)
	expect(rigAnimator.Parent).toBe(controller)

	connection:Disconnect()
end)

it("never stops or destroys foreign tracks during eviction or release", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, _controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)

	local foreignAnimation: Animation = Instance.new("Animation")
	foreignAnimation.AnimationId = "rbxassetid://1"

	local foreign: TestUtils.FakeTrack = TestUtils.Track(animator :: Animator, foreignAnimation)
	foreign:Play()
	harness.foreign[animator :: Animator] = { foreign }

	local playbacks: { Types.AnimationPlayback } = fill(harness, model, TRACK_LIMIT)

	for _, playback: Types.AnimationPlayback in playbacks do
		playback:Stop(0)
	end

	harness.animations.Play(model, `rbxassetid://{TRACK_LIMIT + 1}`)
	model.Parent = nil

	expect(foreign.IsPlaying).toBe(true)
	expect(#foreign.stops).toBe(0)
	expect(foreign.destroyed).toBe(false)
	expect(TestUtils.IsDestroyed(foreignAnimation)).toBe(false)

	foreignAnimation:Destroy()
end)

it("retains no Animators or tracks after long rig churn", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	for index = 1, 50 do
		local model: Model = TestUtils.Rig(if index % 2 == 0 then "Humanoid" else "AnimationController", index % 3 == 0)
		harness.animations.Play(model, "rbxassetid://1")
		harness.animations.Play(model, "rbxassetid://2")

		if index % 2 == 0 then
			model:Destroy()
		else
			model.Parent = nil
		end
	end

	local animators: number, tracks: number = harness.cache:_CountForTests()

	expect(animators).toBe(0)
	expect(tracks).toBe(0)
	expect(#harness.loads).toBe(100)

	for _, track: TestUtils.FakeTrack in harness.loads do
		expect(track.destroyed).toBe(true)
	end
end)
