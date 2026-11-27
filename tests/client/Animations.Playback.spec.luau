--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

local function play(
	harness: TestUtils.Harness,
	model: Model,
	options: Types.AnimationPlayOptions?
): Types.AnimationPlayback
	local playback: Types.AnimationPlayback?, reason: string? =
		harness.animations.Play(model, "rbxassetid://1", options)

	assert(playback ~= nil, reason)

	return playback
end

it("restarts the same cached track on a second Play and makes the earlier handle inert", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local first: Types.AnimationPlayback = play(harness, model)

	local track: TestUtils.FakeTrack = harness.loads[1]
	track.TimePosition = 0.75

	local second: Types.AnimationPlayback = play(harness, model)

	first:Stop()
	first:Destroy()
	first:AdjustSpeed(3)
	first:AdjustWeight(0.2)

	expect(#harness.loads).toBe(1)
	expect(#track.plays).toBe(2)
	expect(track.TimePosition).toBe(0)
	expect(track.IsPlaying).toBe(true)
	expect(track.stops).toEqual({})
	expect(track.speeds).toEqual({})
	expect(track.weights).toEqual({})
	expect(first:GetTrack()).toBeNil()
	expect(second:GetTrack()).toBe(track)
end)

it("resets options on each new playback instead of inheriting the previous cast", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)

	play(harness, model, {
		fadeTime = 0.3,
		weight = 0.5,
		speed = 2,
		priority = Enum.AnimationPriority.Action4,
		looped = true,
	})

	play(harness, model)

	local track: TestUtils.FakeTrack = harness.loads[1]

	expect(track.plays[2]).toEqual({ fadeTime = 0.1, weight = 1, speed = 1, timePosition = 0 })
	expect(track.Priority).toBe(Enum.AnimationPriority.Action)
	expect(track.Looped).toBe(false)
end)

it("stops the current playback with its own fade and keeps the track cached", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback = play(harness, model, { fadeTime = 0.25 })
	local track: TestUtils.FakeTrack = harness.loads[1]

	playback:Stop()
	playback:Stop()
	playback:Destroy()

	local replay: Types.AnimationPlayback = play(harness, model)

	expect(track.stops).toEqual({ 0.25 })
	expect(playback:GetTrack()).toBeNil()
	expect(track.destroyed).toBe(false)
	expect(#harness.loads).toBe(1)
	expect(replay:GetTrack()).toBe(track)
end)

it("uses an explicit Stop fade and treats Destroy as a default-fade Stop", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local track: TestUtils.FakeTrack

	play(harness, model, { fadeTime = 0.2 }):Stop(0)
	track = harness.loads[1]
	play(harness, model, { fadeTime = 0.4 }):Destroy()

	expect(track.stops).toEqual({ 0, 0.4 })
end)

it("adjusts speed and weight only on the current playing handle", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback = play(harness, model)
	local track: TestUtils.FakeTrack = harness.loads[1]

	playback:AdjustSpeed(1.5)
	playback:AdjustWeight(0.4)
	playback:AdjustWeight(0.6, 0.2)
	track:Stop(0)
	playback:AdjustSpeed(4)
	playback:AdjustWeight(0.1)

	expect(track.speeds).toEqual({ 1.5 })
	expect(track.weights).toEqual({ { weight = 0.4 }, { weight = 0.6, fadeTime = 0.2 } })
end)

it("keeps a naturally finished playback current until it is replaced or released", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback = play(harness, model)

	local track: TestUtils.FakeTrack = harness.loads[1]

	track.IsPlaying = false

	expect(playback:GetTrack()).toBe(track)

	playback:Stop()

	expect(playback:GetTrack()).toBeNil()
	expect(track.stops).toEqual({ 0.1 })
end)

it("keeps a replay during a fade current after the earlier fade finishes", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local first: Types.AnimationPlayback = play(harness, model)
	local track: TestUtils.FakeTrack = harness.loads[1]

	first:Stop(0.3)

	expect(track.fading).toBe(true)

	local second: Types.AnimationPlayback = play(harness, model)

	track.fading = false

	expect(#harness.loads).toBe(1)
	expect(track.IsPlaying).toBe(true)
	expect(second:GetTrack()).toBe(track)

	second:AdjustSpeed(2)

	expect(track.speeds).toEqual({ 2 })
end)

it("leaves the running playback untouched when a new Play is rejected", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local running: Types.AnimationPlayback = play(harness, model, { speed = 2, looped = true })
	local track: TestUtils.FakeTrack = harness.loads[1]
	local unsafe: any = harness.animations

	local rejected: Types.AnimationPlayback?, reason: string? = unsafe.Play(model, "rbxassetid://1", { speed = 0 / 0 })

	expect(rejected).toBeNil()
	expect(reason).toBe("AnimationSpeedInvalid")
	expect(#track.plays).toBe(1)
	expect(track.Looped).toBe(true)
	expect(running:GetTrack()).toBe(track)

	running:Stop()

	expect(track.stops).toEqual({ 0.1 })
end)

it("raises a stable error for invalid handle arguments without changing the track", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback = play(harness, model)
	local track: TestUtils.FakeTrack = harness.loads[1]
	local unsafe: any = playback

	local cases: { { call: () -> (), reason: string } } = {
		{
			call = function(): ()
				unsafe:Stop(-1)
			end,
			reason = "AnimationFadeTimeInvalid",
		},
		{
			call = function(): ()
				unsafe:AdjustSpeed(math.huge)
			end,
			reason = "AnimationSpeedInvalid",
		},
		{
			call = function(): ()
				unsafe:AdjustWeight("heavy")
			end,
			reason = "AnimationWeightInvalid",
		},
		{
			call = function(): ()
				unsafe:AdjustWeight(0.5, 0 / 0)
			end,
			reason = "AnimationFadeTimeInvalid",
		},
	}

	for _, case: { call: () -> (), reason: string } in cases do
		local success: boolean, message: any = pcall(case.call)

		expect(success).toBe(false)
		expect(tostring(message)).toContain(case.reason)
	end

	expect(track.stops).toEqual({})
	expect(track.speeds).toEqual({})
	expect(track.weights).toEqual({})
	expect(playback:GetTrack()).toBe(track)
end)

it("returns frozen handles", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local playback: Types.AnimationPlayback = play(harness, model)

	expect(table.isfrozen(playback :: any)).toBe(true)
	expect(table.isfrozen(harness.animations :: any)).toBe(true)
end)
