--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local TagControllerInstanceUtils = require(KRF.server.Tags.utils.TagControllerInstance)
local TagControllerStepUtils = require(KRF.server.Tags.utils.TagControllerStepUtils)

type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord

it("SelectStackRefreshTarget breaks equal remaining-duration ties by oldest applied order", function()
	local firstInstance: TagInstanceRecord = {
		tagId = "Buff.Sprint",
		duration = 5,
		remainingDuration = 2,
		appliedOrder = 4,
	}
	local secondInstance: TagInstanceRecord = {
		tagId = "Buff.Sprint",
		duration = 5,
		remainingDuration = 2,
		appliedOrder = 1,
	}

	local selectedInstance: TagInstanceRecord =
		TagControllerInstanceUtils.SelectStackRefreshTarget({ firstInstance, secondInstance })

	expect(selectedInstance).toBe(secondInstance)
end)

it("SelectOldestAppliedInstanceIndex can choose a later entry when it has the smallest applied order", function()
	local oldestIndex: number = TagControllerInstanceUtils.SelectOldestAppliedInstanceIndex({
		{
			tagId = "Buff.Sprint",
			duration = 5,
			remainingDuration = 5,
			appliedOrder = 3,
		},
		{
			tagId = "Buff.Sprint",
			duration = 5,
			remainingDuration = 5,
			appliedOrder = 0,
		},
	})

	expect(oldestIndex).toBe(2)
end)

it("StepTagInstance returns false and leaves indefinite instances unchanged", function()
	local tagRecord: TagInstanceRecord = {
		tagId = "Status.Rooted",
		duration = nil,
		remainingDuration = nil,
		appliedOrder = 0,
	}

	local expired: boolean = TagControllerStepUtils.StepTagInstance(tagRecord, 5)

	expect(expired).toBe(false)
	expect(tagRecord.remainingDuration).toBeNil()
end)
