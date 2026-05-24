local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local TagTestUtils: any = script.Parent.Parent.Parent.Utils.Tags

type Actor = ActorTypes.Actor
type TagDefinition = TagTypes.TagDefinition
type TagControllerType = TagTypes.TagController
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot

local StepCatalog: { TagDefinition } = require(TagTestUtils.TagControllerStepCatalog)
local RootedRefreshCatalog: { TagDefinition } = require(TagTestUtils.RootedRefreshCatalog)

local function expectActiveTag(
	activeTag: ActiveTagSnapshot,
	expectedTagId: string,
	expectedStackCount: number,
	expectedRemainingDuration: number?
)
	expect(activeTag.tagId).toBe(expectedTagId)
	expect(activeTag.stackCount).toBe(expectedStackCount)
	expect(activeTag.remainingDuration).toBe(expectedRemainingDuration)
end

local function expectTagInstance(
	tagInstance: TagInstanceSnapshot,
	expectedTagId: string,
	expectedDuration: number?,
	expectedRemainingDuration: number?,
	expectedAppliedOrder: number
)
	expect(tagInstance.tagId).toBe(expectedTagId)
	expect(tagInstance.duration).toBe(expectedDuration)
	expect(tagInstance.remainingDuration).toBe(expectedRemainingDuration)
	expect(tagInstance.appliedOrder).toBe(expectedAppliedOrder)
end

local function createControllerWithCatalog(catalog: { TagDefinition }): (TagControllerType, Actor)
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(catalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: TagControllerType = TagController.new(actor)

	return controller, actor
end

local function createController(): (TagControllerType, Actor)
	return createControllerWithCatalog(StepCatalog)
end

local function runWithManualStepping(callback: () -> ())
	TagController._setAutomaticSteppingEnabledForTests(false)

	local success: boolean, failureReason: unknown = pcall(callback)

	TagController._setAutomaticSteppingEnabledForTests(true)

	if not success then
		error(tostring(failureReason))
	end
end

it("ignores non-positive advancement deltas without mutating timed state or firing events", function()
	runWithManualStepping(function()
		local controller = createController()
		local changedCount: number = 0
		local expiredCount: number = 0

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned")
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagChanged:Connect(function()
			changedCount += 1
		end)

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		TagController.Step(0)
		TagController.Step(-0.25)

		local tagInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.Stunned")

		expect(changedCount).toBe(0)
		expect(expiredCount).toBe(0)
		expect(#tagInstances).toBe(1)
		expectTagInstance(tagInstances[1], "Status.Stunned", 1.5, 1.5, 0)
	end)
end)

it(
	"counts timed stack instances down deterministically and keeps the longest remaining duration in GetActiveTags",
	function()
		runWithManualStepping(function()
			local controller = createController()

			local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", {
				duration = 6,
			})
			expect(firstAdded).toBe(true)
			expect(firstReason).toBeNil()

			local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", {
				duration = 2,
			})
			expect(secondAdded).toBe(true)
			expect(secondReason).toBeNil()

			TagController.Step(1.5)

			local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()
			local tagInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Buff.Sprint")

			expect(#activeTags).toBe(1)
			expectActiveTag(activeTags[1], "Buff.Sprint", 2, 4.5)
			expect(#tagInstances).toBe(2)
			expectTagInstance(tagInstances[1], "Buff.Sprint", 6, 4.5, 0)
			expectTagInstance(tagInstances[2], "Buff.Sprint", 2, 0.5, 1)
		end)
	end
)

it("leaves indefinite tags unchanged when time advances", function()
	runWithManualStepping(function()
		local controller = createController()

		local rootedAdded: boolean, rootedReason: string? = controller:AddTag("Status.Rooted")
		expect(rootedAdded).toBe(true)
		expect(rootedReason).toBeNil()

		local stunnedAdded: boolean, stunnedReason: string? = controller:AddTag("Status.Stunned")
		expect(stunnedAdded).toBe(true)
		expect(stunnedReason).toBeNil()

		TagController.Step(1)

		local rootedInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.Rooted")
		local stunnedInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.Stunned")

		expect(#rootedInstances).toBe(1)
		expectTagInstance(rootedInstances[1], "Status.Rooted", nil, nil, 0)
		expect(#stunnedInstances).toBe(1)
		expectTagInstance(stunnedInstances[1], "Status.Stunned", 1.5, 0.5, 1)
	end)
end)

it("expires a timed tag at zero and fires expired then changed without firing removed", function()
	runWithManualStepping(function()
		local controller, actor = createController()
		local eventOrder: { string } = {}

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned")
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagExpired:Connect(function(changedActor, changedTagId)
			table.insert(eventOrder, "expired")
			expect(changedActor).toBe(actor)
			expect(changedTagId).toBe("Status.Stunned")
		end)

		controller.OnTagChanged:Connect(function(changedActor, changedTagId)
			table.insert(eventOrder, "changed")
			expect(changedActor).toBe(actor)
			expect(changedTagId).toBe("Status.Stunned")
		end)

		controller.OnTagRemoved:Connect(function()
			table.insert(eventOrder, "removed")
		end)

		TagController.Step(1.5)

		expect(eventOrder).toEqual({ "expired", "changed" })
		expect(controller:HasTag("Status.Stunned")).toBe(false)
		expect(#controller:GetActiveTags()).toBe(0)
	end)
end)

it("expires a timed tag when one advancement step drops it below zero", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
			duration = 0.5,
		})
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		TagController.Step(1)

		expect(expiredCount).toBe(1)
		expect(controller:HasTag("Status.Stunned")).toBe(false)
		expect(#controller:GetTagInstances("Status.Stunned")).toBe(0)
	end)
end)

it("expires every eligible timed stack instance in the same pass", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0
		local changedCount: number = 0
		local removedCount: number = 0

		local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 1,
		})
		expect(firstAdded).toBe(true)
		expect(firstReason).toBeNil()

		local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(secondAdded).toBe(true)
		expect(secondReason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		controller.OnTagChanged:Connect(function()
			changedCount += 1
		end)

		controller.OnTagRemoved:Connect(function()
			removedCount += 1
		end)

		TagController.Step(1)

		expect(expiredCount).toBe(2)
		expect(changedCount).toBe(2)
		expect(removedCount).toBe(0)
		expect(controller:HasTag("Buff.Sprint")).toBe(false)
		expect(#controller:GetTagInstances("Buff.Sprint")).toBe(0)
	end)
end)

it("expires one stacked timed instance while leaving later-expiring instances active", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0
		local changedCount: number = 0

		local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 1,
		})
		expect(firstAdded).toBe(true)
		expect(firstReason).toBeNil()

		local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 3,
		})
		expect(secondAdded).toBe(true)
		expect(secondReason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		controller.OnTagChanged:Connect(function()
			changedCount += 1
		end)

		TagController.Step(1.5)

		local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()
		local remainingInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Buff.Sprint")

		expect(expiredCount).toBe(1)
		expect(changedCount).toBe(1)
		expect(controller:HasTag("Buff.Sprint")).toBe(true)
		expect(#activeTags).toBe(1)
		expectActiveTag(activeTags[1], "Buff.Sprint", 1, 1.5)
		expect(#remainingInstances).toBe(1)
		expectTagInstance(remainingInstances[1], "Buff.Sprint", 3, 1.5, 1)
	end)
end)

it("refresh resets remaining duration to the newly resolved value instead of extending it", function()
	runWithManualStepping(function()
		local controller = createController()

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
			duration = 5,
		})
		expect(added).toBe(true)
		expect(reason).toBeNil()

		TagController.Step(2)

		local refreshed: boolean, refreshReason: string? = controller:AddTag("Status.Stunned", {
			duration = 4,
		})
		expect(refreshed).toBe(true)
		expect(refreshReason).toBeNil()
		local tagInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.Stunned")
		expect(#tagInstances).toBe(1)
		expectTagInstance(tagInstances[1], "Status.Stunned", 4, 4, 0)
	end)
end)

it("reapplying an indefinite Refresh tag does not accidentally introduce timed expiry behavior", function()
	runWithManualStepping(function()
		local controller = createControllerWithCatalog(RootedRefreshCatalog)
		local expiredCount: number = 0

		local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.RootedRefresh")
		expect(firstAdded).toBe(true)
		expect(firstReason).toBeNil()

		local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.RootedRefresh")
		expect(secondAdded).toBe(true)
		expect(secondReason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		TagController.Step(10)

		local tagInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.RootedRefresh")
		expect(expiredCount).toBe(0)
		expect(controller:HasTag("Status.RootedRefresh")).toBe(true)
		expect(#tagInstances).toBe(1)
		expectTagInstance(tagInstances[1], "Status.RootedRefresh", nil, nil, 0)
	end)
end)

it("Destroy removes timed instances from future advancement", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
			duration = 0.5,
		})
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		controller:Destroy()
		TagController.Step(1)

		expect(expiredCount).toBe(0)
		expect(controller:HasTag("Status.Stunned")).toBe(false)
		expect(#controller:GetTagInstances("Status.Stunned")).toBe(0)
		expect(#controller:GetActiveTags()).toBe(0)
	end)
end)

it("manual RemoveTag does not fire OnTagExpired for timed instances", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0
		local removedCount: number = 0

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned")
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		controller.OnTagRemoved:Connect(function()
			removedCount += 1
		end)

		local removed: boolean, removeReason: string? = controller:RemoveTag("Status.Stunned")
		expect(removed).toBe(true)
		expect(removeReason).toBeNil()
		expect(expiredCount).toBe(0)
		expect(removedCount).toBe(1)
	end)
end)

it("manual RemoveSingleTag does not fire OnTagExpired for timed instances", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0
		local removedCount: number = 0

		local added: boolean, reason: string? = controller:AddTag("Status.Stunned")
		expect(added).toBe(true)
		expect(reason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1
		end)

		controller.OnTagRemoved:Connect(function()
			removedCount += 1
		end)

		local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Status.Stunned")
		expect(removed).toBe(true)
		expect(removeReason).toBeNil()
		expect(expiredCount).toBe(0)
		expect(removedCount).toBe(1)
	end)
end)

it("remains stable when expiry listeners mutate tag state during the advancement pass", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredTagIds: { string } = {}
		local changedTagIds: { string } = {}

		local stunnedAdded: boolean, stunnedReason: string? = controller:AddTag("Status.Stunned", {
			duration = 0.5,
		})
		expect(stunnedAdded).toBe(true)
		expect(stunnedReason).toBeNil()

		local sprintAdded: boolean, sprintReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(sprintAdded).toBe(true)
		expect(sprintReason).toBeNil()

		controller.OnTagExpired:Connect(function(_actor, expiredTagId)
			table.insert(expiredTagIds, expiredTagId)

			if expiredTagId == "Status.Stunned" then
				local added: boolean, reason: string? = controller:AddTag("Status.Rooted")
				expect(added).toBe(true)
				expect(reason).toBeNil()
			elseif expiredTagId == "Buff.Sprint" then
				local removed: boolean, reason: string? = controller:RemoveTag("Status.Rooted")
				expect(removed).toBe(true)
				expect(reason).toBeNil()
			end
		end)

		controller.OnTagChanged:Connect(function(_actor, changedTagId)
			table.insert(changedTagIds, changedTagId)
		end)

		TagController.Step(1)

		expect(expiredTagIds).toEqual({ "Status.Stunned", "Buff.Sprint" })
		expect(changedTagIds).toEqual({
			"Status.Rooted",
			"Status.Stunned",
			"Status.Rooted",
			"Buff.Sprint",
		})
		expect(controller:HasTag("Status.Stunned")).toBe(false)
		expect(controller:HasTag("Buff.Sprint")).toBe(false)
		expect(controller:HasTag("Status.Rooted")).toBe(false)
		expect(#controller:GetActiveTags()).toBe(0)
	end)
end)

it("skips a later expired record cleanly when an earlier expiry destroys the controller", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredTagIds: { string } = {}

		local stunnedAdded: boolean, stunnedReason: string? = controller:AddTag("Status.Stunned", {
			duration = 0.5,
		})
		expect(stunnedAdded).toBe(true)
		expect(stunnedReason).toBeNil()

		local sprintAdded: boolean, sprintReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(sprintAdded).toBe(true)
		expect(sprintReason).toBeNil()

		controller.OnTagExpired:Connect(function()
			table.insert(expiredTagIds, "expired")
			controller:Destroy()
		end)

		TagController.Step(1)

		expect(#expiredTagIds).toBe(1)
		expect(#controller:GetActiveTags()).toBe(0)
		expect(#controller:GetTagInstances("Status.Stunned")).toBe(0)
		expect(#controller:GetTagInstances("Buff.Sprint")).toBe(0)
	end)
end)

it("skips a later expired record when an earlier expiry removes that tag entirely", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredTagIds: { string } = {}

		local stunnedAdded: boolean, stunnedReason: string? = controller:AddTag("Status.Stunned", {
			duration = 0.5,
		})
		expect(stunnedAdded).toBe(true)
		expect(stunnedReason).toBeNil()

		local sprintAdded: boolean, sprintReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(sprintAdded).toBe(true)
		expect(sprintReason).toBeNil()

		controller.OnTagExpired:Connect(function(_actor, expiredTagId)
			table.insert(expiredTagIds, expiredTagId)

			if expiredTagId == "Status.Stunned" then
				local removed: boolean, removeReason: string? = controller:RemoveTag("Buff.Sprint")
				expect(removed).toBe(true)
				expect(removeReason).toBeNil()
			end
		end)

		TagController.Step(1)

		expect(expiredTagIds).toEqual({ "Status.Stunned" })
		expect(controller:HasTag("Status.Stunned")).toBe(false)
		expect(controller:HasTag("Buff.Sprint")).toBe(false)
	end)
end)

it("skips a stale expired stack record when an earlier expiry removes that specific instance", function()
	runWithManualStepping(function()
		local controller = createController()
		local expiredCount: number = 0

		local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(firstAdded).toBe(true)
		expect(firstReason).toBeNil()

		local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 0.5,
		})
		expect(secondAdded).toBe(true)
		expect(secondReason).toBeNil()

		local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", {
			duration = 5,
		})
		expect(thirdAdded).toBe(true)
		expect(thirdReason).toBeNil()

		controller.OnTagExpired:Connect(function()
			expiredCount += 1

			if expiredCount == 1 then
				local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")
				expect(removed).toBe(true)
				expect(removeReason).toBeNil()
			end
		end)

		TagController.Step(1)

		local remainingInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Buff.Sprint")
		expect(expiredCount).toBe(1)
		expect(controller:HasTag("Buff.Sprint")).toBe(true)
		expect(#remainingInstances).toBe(1)
		expectTagInstance(remainingInstances[1], "Buff.Sprint", 5, 4, 2)
	end)
end)
