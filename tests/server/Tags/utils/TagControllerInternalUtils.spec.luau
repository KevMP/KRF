--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagControllerInstanceUtils = require(KRF.server.Tags.utils.TagControllerInstance)
local TagControllerStepUtils = require(KRF.server.Tags.utils.TagControllerStepUtils)
local TagControllerTickUtils = require(KRF.server.Tags.utils.TagControllerTickUtils)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local TagTestUtils: any = script.Parent.Parent.Parent.Utils.Tags

type Actor = ActorTypes.Actor
type TagDefinition = TagTypes.TagDefinition
type TagInstanceRecord = TagControllerInstanceUtils.TagInstanceRecord
type StepTagInstanceResult = TagControllerStepUtils.StepTagInstanceResult

local MixedTagCatalog: { TagDefinition } = require(TagTestUtils.MixedTagCatalog) :: { TagDefinition }

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

it("CreateTagInstance seeds tick countdown from registered metadata", function()
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(MixedTagCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local factoryContext: TagControllerInstanceUtils.TagInstanceFactoryContext = {
		nextAppliedOrder = 0,
	}

	local firstInstance: TagInstanceRecord =
		TagControllerInstanceUtils.CreateTagInstance(factoryContext, "Status.OnFire", 5)
	local secondInstance: TagInstanceRecord =
		TagControllerInstanceUtils.CreateTagInstance(factoryContext, "Status.Rooted", nil)

	expect(firstInstance.remainingToNextTick).toBe(1)
	expect(secondInstance.remainingToNextTick).toBeNil()
end)

it("StepTagInstance returns false flags and leaves indefinite instances unchanged", function()
	local tagRecord: TagInstanceRecord = {
		tagId = "Status.Rooted",
		duration = nil,
		remainingDuration = nil,
		appliedOrder = 0,
	}

	local stepResult: StepTagInstanceResult = TagControllerStepUtils.StepTagInstance(tagRecord, 5, nil)

	expect(stepResult.shouldTick).toBe(false)
	expect(stepResult.shouldExpire).toBe(false)
	expect(tagRecord.remainingDuration).toBeNil()
	expect(tagRecord.remainingToNextTick).toBeNil()
end)

it("StepTagInstance reports a due tick and resets the countdown when the interval elapses", function()
	local tagDefinition: TagDefinition = {
		id = "Status.OnFire",
		defaultDuration = 5,
		tickInterval = 1,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		onTick = function(_actor, _deltaTime): ()
			return
		end,
	}
	local tagRecord: TagInstanceRecord = {
		tagId = "Status.OnFire",
		duration = 5,
		remainingDuration = 5,
		remainingToNextTick = 0.25,
		appliedOrder = 0,
	}

	local stepResult: StepTagInstanceResult = TagControllerStepUtils.StepTagInstance(tagRecord, 0.5, tagDefinition)

	expect(stepResult.shouldTick).toBe(true)
	expect(stepResult.shouldExpire).toBe(false)
	expect(tagRecord.remainingToNextTick).toBe(1)
	expect(tagRecord.remainingDuration).toBe(4.5)
end)

it("StepTagInstance leaves stale countdown state untouched when metadata is unavailable", function()
	local tagRecord: TagInstanceRecord = {
		tagId = "Status.Missing",
		duration = 2,
		remainingDuration = 2,
		remainingToNextTick = 0.25,
		appliedOrder = 0,
	}

	local stepResult: StepTagInstanceResult = TagControllerStepUtils.StepTagInstance(tagRecord, 0.5, nil)

	expect(stepResult.shouldTick).toBe(true)
	expect(stepResult.shouldExpire).toBe(false)
	expect(tagRecord.remainingToNextTick).toBe(-0.25)
	expect(tagRecord.remainingDuration).toBe(1.5)
end)

it("FireProtectedOnTick returns early when no hook is defined", function()
	local actor: Actor = ActorEntity.new()
	local tagDefinition: TagDefinition = {
		id = "Status.Passive",
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
	}

	local succeeded: boolean, failureReason: unknown = pcall(function()
		TagControllerTickUtils.FireProtectedOnTick(tagDefinition, actor, 0.5)
	end)

	expect(succeeded).toBe(true)
	expect(failureReason).toBeNil()
end)

it("FireProtectedOnTick passes the actor and delta time to the consumer hook", function()
	local actor: Actor = ActorEntity.new()
	local capturedActor: Actor? = nil
	local capturedDeltaTime: number? = nil
	local tagDefinition: TagDefinition = {
		id = "Status.OnFire",
		tickInterval = 1,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		onTick = function(tickActor, deltaTime): ()
			capturedActor = tickActor
			capturedDeltaTime = deltaTime
		end,
	}

	TagControllerTickUtils.FireProtectedOnTick(tagDefinition, actor, 0.75)

	expect(capturedActor).toBe(actor)
	expect(capturedDeltaTime).toBe(0.75)
end)
