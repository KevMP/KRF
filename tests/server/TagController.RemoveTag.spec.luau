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

local function createController()
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(TestCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor = ActorEntity.new()
	local controller = TagController.new(actor)

	return controller, actor
end

local function getActiveTagsById(controller: unknown): any
	return ((controller :: unknown) :: any)._activeTagsById
end

it("RemoveTag removes all active instances of a stacked tag", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 2 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()
	expect(#activeTagsById["Buff.Sprint"]).toBe(3)

	local removed: boolean, removeReason: string? = controller:RemoveTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(activeTagsById["Buff.Sprint"]).toBeNil()
end)

it("RemoveTag returns false with TagNotActive when the tag is not active", function()
	local controller = createController()

	local removed: boolean, removeReason: string? = controller:RemoveTag("Buff.Sprint")

	expect(removed).toBe(false)
	expect(removeReason).toBe("TagNotActive")
end)

it("fires removed then changed when RemoveTag succeeds", function()
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

	local removed: boolean, removeReason: string? = controller:RemoveTag("Status.Rooted")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(eventOrder).toEqual({ "removed", "changed" })
end)
