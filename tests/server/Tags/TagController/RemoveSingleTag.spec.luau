--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagController = require(KRF.server.Tags.TagController)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local TagTypes = require(KRF.server.Tags.types)

type TagDefinition = TagTypes.TagDefinition
type TagControllerType = TagTypes.TagController

local TestCatalog: { TagDefinition } = {
	{
		id = "Status.Rooted",
		duplicateBehavior = "Ignore",
		visibility = "ServerOnly",
	},
	{
		id = "Buff.Sprint",
		defaultDuration = 6,
		duplicateBehavior = "Stack",
		maxStacks = 3,
		visibility = "ClientVisible",
	},
}

local function createController(): (TagControllerType, any)
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(TestCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor = ActorEntity.new()
	local controller: TagControllerType = TagController.new(actor)

	return controller, actor
end

it("RemoveSingleTag removes exactly one instance of a stacked tag", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 2 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({
		{
			tagId = "Buff.Sprint",
			duration = 4,
			remainingDuration = 4,
			appliedOrder = 1,
		},
		{
			tagId = "Buff.Sprint",
			duration = 2,
			remainingDuration = 2,
			appliedOrder = 2,
		},
	})
end)

it("RemoveSingleTag leaves remaining instances active when more than one instance exists", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(controller:HasTag("Buff.Sprint")).toBe(true)
	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({
		{
			tagId = "Buff.Sprint",
			duration = 4,
			remainingDuration = 4,
			appliedOrder = 1,
		},
	})
end)

it("RemoveSingleTag returns false with TagNotActive when the tag is not active", function()
	local controller = createController()

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(false)
	expect(removeReason).toBe("TagNotActive")
end)

it("RemoveSingleTag clears the tag entirely when only one active instance exists", function()
	local controller = createController()

	local added: boolean, addReason: string? = controller:AddTag("Status.Rooted")
	expect(added).toBe(true)
	expect(addReason).toBeNil()
	expect(controller:HasTag("Status.Rooted")).toBe(true)

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Status.Rooted")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(controller:HasTag("Status.Rooted")).toBe(false)
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({})
end)

it("RemoveSingleTag fires removed then changed when removing one instance from a stacked tag", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	controller.OnTagRemoved:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "removed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Buff.Sprint")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Buff.Sprint")
	end)

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(eventOrder).toEqual({ "removed", "changed" })
	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({
		{
			tagId = "Buff.Sprint",
			duration = 4,
			remainingDuration = 4,
			appliedOrder = 1,
		},
	})
end)

it("RemoveSingleTag fires removed then changed when removing the only active instance", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	local added: boolean, addReason: string? = controller:AddTag("Status.Rooted")
	expect(added).toBe(true)
	expect(addReason).toBeNil()

	controller.OnTagRemoved:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "removed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Rooted")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Rooted")
	end)

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Status.Rooted")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(eventOrder).toEqual({ "removed", "changed" })
end)

it("RemoveSingleTag does not fire mutation events when the tag is not active", function()
	local controller = createController()
	local eventCount: number = 0

	controller.OnTagRemoved:Connect(function()
		eventCount += 1
	end)

	controller.OnTagChanged:Connect(function()
		eventCount += 1
	end)

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(false)
	expect(removeReason).toBe("TagNotActive")
	expect(eventCount).toBe(0)
end)
