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

afterEach(function()
	TestUtils.Cleanup()
end)

it("rejects a value that is not a Model before touching any rig", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local _model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)
	local unsafe: any = harness.animations

	local playback: Types.AnimationPlayback?, reason: string? = unsafe.Play(controller, "rbxassetid://1")
	local missing: Types.AnimationPlayback?, missingReason: string? = unsafe.Play(nil, "rbxassetid://1")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationModelInvalid")
	expect(missing).toBeNil()
	expect(missingReason).toBe("AnimationModelInvalid")
	expect(controller:FindFirstChildOfClass("Animator")).toBeNil()
	expect(#harness.loads).toBe(0)
end)

it("rejects blank, malformed and non-string animation IDs with a stable reason", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)
	local unsafe: any = harness.animations

	local cases: { any } = {
		"",
		"   ",
		"123456",
		"rbxassetid://",
		"rbxassetid://abc",
		"rbxassetid://-5",
		"rbxassetid://0",
		"rbxassetid://1.5",
		"rbxassetid://12345678901234567890",
		"rbxassetid://9223372036854775808",
		"rbxasset://animations/idle.anim",
		"https://example.com/asset/?id=12",
		123456,
		true,
	}

	for _, animationId: any in cases do
		local playback: Types.AnimationPlayback?, reason: string? = unsafe.Play(model, animationId)

		expect(playback).toBeNil()
		expect(reason).toBe("AnimationIdInvalid")
	end

	expect(controller:FindFirstChildOfClass("Animator")).toBeNil()
	expect(#harness.loads).toBe(0)
end)

it("normalizes equivalent content ID spellings to one cached track", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	local spellings: { string } = {
		"rbxassetid://507766388",
		"  rbxassetid://507766388  ",
		"RBXASSETID://0507766388",
		"http://www.roblox.com/asset/?id=507766388",
		"https://www.roblox.com/asset?id=507766388",
		"https://roblox.com/asset/?id=507766388",
	}

	for _, animationId: string in spellings do
		local playback: Types.AnimationPlayback? = harness.animations.Play(model, animationId)

		expect((playback :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[1])
	end

	expect(#harness.loads).toBe(1)
	expect(harness.loads[1].animationId).toBe("rbxassetid://507766388")
end)

it("accepts the largest 64-bit asset ID", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, "rbxassetid://9223372036854775807")

	expect(reason).toBeNil()
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[1])
	expect(harness.loads[1].animationId).toBe("rbxassetid://9223372036854775807")
end)

it("rejects malformed options and each invalid option field with its own reason", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local unsafe: any = harness.animations

	local cases: { { options: any, reason: string } } = {
		{ options = 5, reason = "AnimationOptionsInvalid" },
		{ options = setmetatable({}, {}), reason = "AnimationOptionsInvalid" },
		{ options = { fade = 0.2 }, reason = "AnimationOptionUnknown" },
		{ options = { [1] = 0.2 }, reason = "AnimationOptionUnknown" },
		{ options = { fadeTime = -0.1 }, reason = "AnimationFadeTimeInvalid" },
		{ options = { fadeTime = math.huge }, reason = "AnimationFadeTimeInvalid" },
		{ options = { fadeTime = 0 / 0 }, reason = "AnimationFadeTimeInvalid" },
		{ options = { fadeTime = "0.1" }, reason = "AnimationFadeTimeInvalid" },
		{ options = { weight = -1 }, reason = "AnimationWeightInvalid" },
		{ options = { weight = -math.huge }, reason = "AnimationWeightInvalid" },
		{ options = { speed = math.huge }, reason = "AnimationSpeedInvalid" },
		{ options = { speed = 0 / 0 }, reason = "AnimationSpeedInvalid" },
		{ options = { priority = "Action" }, reason = "AnimationPriorityInvalid" },
		{ options = { priority = Enum.KeyCode.Q }, reason = "AnimationPriorityInvalid" },
		{ options = { looped = 1 }, reason = "AnimationLoopedInvalid" },
	}

	for _, case: { options: any, reason: string } in cases do
		local playback: Types.AnimationPlayback?, reason: string? = unsafe.Play(model, "rbxassetid://1", case.options)

		expect(playback).toBeNil()
		expect(reason).toBe(case.reason)
	end

	expect(#harness.loads).toBe(0)
end)

it("plays with deterministic defaults when no options are given", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	harness.animations.Play(model, "rbxassetid://1")

	local track: TestUtils.FakeTrack = harness.loads[1]

	expect(track.plays).toEqual({ { fadeTime = 0.1, weight = 1, speed = 1, timePosition = 0 } })
	expect(track.Priority).toBe(Enum.AnimationPriority.Action)
	expect(track.Looped).toBe(false)
	expect(track.TimePosition).toBe(0)
end)

it("applies every supplied option and accepts zero weight", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	harness.animations.Play(model, "rbxassetid://1", {
		fadeTime = 0,
		weight = 0,
		speed = 2,
		priority = Enum.AnimationPriority.Movement,
		looped = true,
	})

	local track: TestUtils.FakeTrack = harness.loads[1]

	expect(track.plays).toEqual({ { fadeTime = 0, weight = 0, speed = 2, timePosition = 0 } })
	expect(track.Priority).toBe(Enum.AnimationPriority.Movement)
	expect(track.Looped).toBe(true)
end)

it("starts a negative-speed playback from the end of the loaded track", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	harness.animations.Play(model, "rbxassetid://1")

	local track: TestUtils.FakeTrack = harness.loads[1]
	track.Length = 2.5

	harness.animations.Play(model, "rbxassetid://1", { speed = -1 })

	expect(track.plays[2].speed).toBe(-1)
	expect(track.TimePosition).toBe(2.5)
end)

it("requires the Model to be inside a WorldRoot and never reparents it", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)
	model.Parent = ReplicatedStorage

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationModelNotInWorld")
	expect(model.Parent).toBe(ReplicatedStorage)
	expect(controller:FindFirstChildOfClass("Animator")).toBeNil()
end)

it("plays on a rig inside a WorldModel outside Workspace", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	local world: WorldModel = Instance.new("WorldModel")
	world.Parent = ReplicatedStorage
	model.Parent = world

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")

	expect(reason).toBeNil()
	expect((playback :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[1])

	world:Destroy()
end)

it("fails a Model without a direct Humanoid or AnimationController and invents no rig", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = Instance.new("Model")
	local folder: Folder = Instance.new("Folder")

	local nested: Humanoid = Instance.new("Humanoid")
	nested.Parent = folder
	folder.Parent = model
	model.Parent = Workspace

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationRigMissing")
	expect(#model:GetChildren()).toBe(1)
	expect(nested:FindFirstChildOfClass("Animator")).toBeNil()

	model:Destroy()
end)

it("creates an Animator under a Humanoid that has none and reuses it afterwards", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)

	harness.animations.Play(model, "rbxassetid://1")
	local animator: Animator = TestUtils.Animator(controller)
	harness.animations.Play(model, "rbxassetid://2")

	expect(animator).never.toBeNil()
	expect(#controller:GetChildren()).toBe(1)
	expect(harness.loads[1].animator).toBe(animator)
	expect(harness.loads[2].animator).toBe(animator)
end)

it("reuses an existing Animator under an AnimationController", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance, animator: Animator? = TestUtils.Rig("AnimationController", true)

	harness.animations.Play(model, "rbxassetid://1")

	expect(harness.loads[1].animator).toBe(animator)
	expect(#controller:GetChildren()).toBe(1)
end)

it("prefers a direct Humanoid over a direct AnimationController", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("AnimationController", true)

	local humanoid: Humanoid = Instance.new("Humanoid")
	humanoid.Parent = model

	harness.animations.Play(model, "rbxassetid://1")

	expect(harness.loads[1].animator.Parent).toBe(humanoid)
	expect(#controller:GetChildren()).toBe(1)
end)

it("destroys only the Animator it just created when the first load fails", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)
	harness.failLoad = true

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationLoadFailed")
	local animators: number = harness.cache:_CountForTests()

	expect(controller:FindFirstChildOfClass("Animator")).toBeNil()
	expect(animators).toBe(0)
end)

it("keeps an existing Animator and its cached tracks when a later load fails", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)

	local first: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")
	local animator: Animator = TestUtils.Animator(controller)

	harness.failLoad = true

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://2")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationLoadFailed")
	expect(animator.Parent).toBe(controller)
	expect((first :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[1])
	expect(harness.loads[1].destroyed).toBe(false)
end)

it("never destroys an externally supplied Animator after a failed load", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance, animator: Animator? = TestUtils.Rig("Humanoid", true)
	harness.failLoad = true

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationLoadFailed")
	expect((animator :: Animator).Parent).toBe(controller)
	expect(harness.cache:Holds(animator :: Animator)).toBe(false)
end)

it("destroys the Animation it created when loading fails", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	harness.failLoad = true

	harness.animations.Play(model, "rbxassetid://1")

	expect(#harness.attempts).toBe(1)
	expect(TestUtils.IsDestroyed(harness.attempts[1])).toBe(true)
end)

it("keeps the running playback and its track when a later Play of that track fails", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local running: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1", { looped = true })

	local track: TestUtils.FakeTrack = harness.loads[1]
	track.failPlay = true

	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, "rbxassetid://1", { priority = Enum.AnimationPriority.Idle })

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationPlayFailed")
	expect((running :: Types.AnimationPlayback):GetTrack()).toBe(track)
	expect(track.IsPlaying).toBe(true)
	expect(track.Looped).toBe(true)
	expect(track.Priority).toBe(Enum.AnimationPriority.Action)
	expect(track.stops).toEqual({})
	expect(track.destroyed).toBe(false)
	expect(#harness.loads).toBe(1)
end)

it("drops a newly loaded track whose first Play fails and removes the Animator it created", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model, controller: Instance = TestUtils.Rig("Humanoid", false)
	harness.failNewPlays = true

	local playback: Types.AnimationPlayback?, reason: string? = harness.animations.Play(model, "rbxassetid://1")
	local broken: TestUtils.FakeTrack = harness.loads[1]

	expect(playback).toBeNil()
	expect(reason).toBe("AnimationPlayFailed")
	expect(broken.destroyed).toBe(true)
	expect(TestUtils.IsDestroyed(broken.animation)).toBe(true)
	expect(controller:FindFirstChildOfClass("Animator")).toBeNil()

	harness.failNewPlays = false

	local replacement: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")

	expect(#harness.loads).toBe(2)
	expect((replacement :: Types.AnimationPlayback):GetTrack()).toBe(harness.loads[2])
end)
