--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local KRF = require(ReplicatedStorage.Packages.KRF)
local Client = require(ReplicatedStorage.Packages.KRF.client)
local NativeAnimationPort = require(ReplicatedStorage.Packages.KRF.client.Presentation.utils.NativeAnimationPort)
local TestUtils = require(script.Parent.Utils.AnimationTestUtils)

afterEach(function()
	TestUtils.Cleanup()
end)

it("plays on a plain rig through the public facade without Client.Init", function()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)

	local playback: KRF.AnimationPlayback?, reason: string? = KRF.Animations.Play(model, "rbxassetid://507766388", {
		fadeTime = 0.15,
		speed = 1.2,
		priority = Enum.AnimationPriority.Action,
	})

	local current: KRF.AnimationPlayback = assert(playback, reason)
	local track: AnimationTrack = assert(current:GetTrack())

	expect(Client._IsInitialized()).toBe(false)
	expect(track:IsA("AnimationTrack")).toBe(true)
	expect(track.Animation.AnimationId).toBe("rbxassetid://507766388")
	expect(track.Priority).toBe(Enum.AnimationPriority.Action)
	expect(track.Looped).toBe(false)
	expect(controller:FindFirstChildOfClass("Animator")).never.toBeNil()

	current:Destroy()

	expect(current:GetTrack()).toBeNil()
end)

it("reuses its own native track and leaves a track another system loaded alone", function()
	local model: Model, _controller: Instance, animator: Animator? = TestUtils.Rig("AnimationController", true)
	local rigAnimator: Animator = animator :: Animator

	local foreignAnimation: Animation = Instance.new("Animation")
	foreignAnimation.AnimationId = "rbxassetid://507766388"

	local foreign: AnimationTrack = rigAnimator:LoadAnimation(foreignAnimation)
	foreign:Play()

	local first: KRF.AnimationPlayback = assert(KRF.Animations.Play(model, "rbxassetid://507766388"))
	local firstTrack: AnimationTrack = assert(first:GetTrack())
	local second: KRF.AnimationPlayback = assert(KRF.Animations.Play(model, "rbxassetid://507766388"))

	expect(second:GetTrack()).toBe(firstTrack)
	expect(firstTrack).never.toBe(foreign)
	expect(first:GetTrack()).toBeNil()
	expect(firstTrack.IsPlaying).toBe(true)

	second:Stop(0)
	rigAnimator:Destroy()

	expect(second:GetTrack()).toBeNil()
	expect(foreign.IsPlaying).toBe(true)

	foreignAnimation:Destroy()
end)

it("loads through the native port and lists the played track as busy", function()
	local _model: Model, _controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	local rigAnimator: Animator = animator :: Animator

	local animation: Animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://507766388"

	local track: AnimationTrack = NativeAnimationPort.Load(rigAnimator, animation)

	expect(table.find(NativeAnimationPort.GetPlayingTracks(rigAnimator), track)).toBeNil()

	track:Play()

	expect(table.find(NativeAnimationPort.GetPlayingTracks(rigAnimator), track)).never.toBeNil()

	track:Destroy()
	animation:Destroy()
end)
