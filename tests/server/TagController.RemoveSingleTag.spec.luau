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

it("RemoveSingleTag removes exactly one instance of a stacked tag", function()
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

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(#activeTagsById["Buff.Sprint"]).toBe(2)
end)

it("RemoveSingleTag leaves remaining instances active when more than one instance exists", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(#activeTagsById["Buff.Sprint"]).toBe(1)
	expect(activeTagsById["Buff.Sprint"][1].duration).toBe(4)
end)

it("RemoveSingleTag returns false with TagNotActive when the tag is not active", function()
	local controller = createController()

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(false)
	expect(removeReason).toBe("TagNotActive")
end)

it("RemoveSingleTag removes the oldest applied active instance", function()
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

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()

	local remainingInstances = activeTagsById["Buff.Sprint"]
	expect(#remainingInstances).toBe(2)
	expect(remainingInstances[1].appliedOrder).toBe(1)
	expect(remainingInstances[2].appliedOrder).toBe(2)
end)

it("RemoveSingleTag clears the tag entirely when only one active instance exists", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local added: boolean, addReason: string? = controller:AddTag("Status.Rooted")
	expect(added).toBe(true)
	expect(addReason).toBeNil()
	expect(#activeTagsById["Status.Rooted"]).toBe(1)

	local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Status.Rooted")

	expect(removed).toBe(true)
	expect(removeReason).toBeNil()
	expect(activeTagsById["Status.Rooted"]).toBeNil()
end)

it(
	"RemoveSingleTag removes the oldest applied instance even when applied order is stored out of array order",
	function()
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

		activeTagsById["Buff.Sprint"][1].appliedOrder = 5
		activeTagsById["Buff.Sprint"][2].appliedOrder = 4
		activeTagsById["Buff.Sprint"][3].appliedOrder = 0

		local removed: boolean, removeReason: string? = controller:RemoveSingleTag("Buff.Sprint")

		expect(removed).toBe(true)
		expect(removeReason).toBeNil()
		expect(#activeTagsById["Buff.Sprint"]).toBe(2)
		expect(activeTagsById["Buff.Sprint"][1].appliedOrder).toBe(5)
		expect(activeTagsById["Buff.Sprint"][2].appliedOrder).toBe(4)
	end
)
