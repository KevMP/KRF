--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Instances = require(KRF.client.Presentation.utils.PresentationInstance)
local TestUtils = require(script.Parent.Utils.AnimationTestUtils)

local environment: Types.PresentationSubscriptionEnvironment = {
	IsEligible = function(): boolean
		return false
	end,
	TrackActor = function(): () -> ()
		return function(): () end
	end,
	IsStateReady = function(): boolean
		return false
	end,
	ObserveReadiness = function(): () -> ()
		return function(): () end
	end,
}

local entry: Types.HintEntryEvent =
	table.freeze({ source = "Hint" :: "Hint", event = "Received" :: "Received", hintId = "Cast" })

afterEach(function()
	TestUtils.Cleanup()
end)

local function cast(harness: TestUtils.Harness, model: Model): Types.PresentationContext
	local definition: Types.PresentationDefinition = {
		id = "Cast.Animation",
		entry = { event = Events.Hint.Received, id = "Cast" },
		create = function(ctx: Types.PresentationContext): ()
			local playback: Types.AnimationPlayback? = harness.animations.Play(model, "rbxassetid://1")

			if playback ~= nil then
				ctx:Own(function(): ()
					playback:Destroy()
				end)
			end
		end,
	}

	local context: Types.PresentationContext = Instances.New(definition, entry, environment, function(): () end)
	task.wait()

	return context
end

it("stops the cast's own playback when its Presentation finishes", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local context: Types.PresentationContext = cast(harness, model)
	local track: TestUtils.FakeTrack = harness.loads[1]

	context:Finish()
	task.wait()

	expect(track.stops).toEqual({ 0.1 })
	expect(track.destroyed).toBe(false)
end)

it("leaves a newer cast playing when an older Presentation is cleaned up later", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local older: Types.PresentationContext = cast(harness, model)
	local newer: Types.PresentationContext = cast(harness, model)
	local track: TestUtils.FakeTrack = harness.loads[1]

	older:Finish()
	task.wait()

	expect(#harness.loads).toBe(1)
	expect(#track.plays).toBe(2)
	expect(track.IsPlaying).toBe(true)
	expect(track.stops).toEqual({})

	newer:Finish()
	task.wait()

	expect(track.stops).toEqual({ 0.1 })
end)

it("keeps the Presentation active after its animation ends naturally", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local model: Model = TestUtils.Rig("Humanoid", true)
	local context: Types.PresentationContext = cast(harness, model)

	harness.loads[1].IsPlaying = false

	expect(context:IsActive()).toBe(true)

	context:Finish()
end)
