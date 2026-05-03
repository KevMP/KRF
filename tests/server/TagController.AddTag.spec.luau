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
		id = "Status.Stunned",
		defaultDuration = 1.5,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
	},
	{
		id = "Buff.Sprint",
		defaultDuration = 6,
		duplicateBehavior = "Stack",
		maxStacks = 3,
		visibility = "ClientVisible",
	},
}

local StackWithoutDefaultDurationCatalog: { TagDefinition } = {
	{
		id = "Buff.StackIndefinite",
		duplicateBehavior = "Stack",
		maxStacks = 2,
		visibility = "ServerOnly",
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

it("returns false with a stable error when AddTag receives an unknown tag id", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Unknown")

	expect(added).toBe(false)
	expect(reason).toBe("UnknownTagId:Status.Unknown")
end)

it("creates a first active instance and fires added then changed for an Ignore tag", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	controller.OnTagAdded:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "added")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Rooted")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Rooted")
	end)

	local added: boolean, reason: string? = controller:AddTag("Status.Rooted")
	local activeTagsById = getActiveTagsById(controller)

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(eventOrder).toEqual({ "added", "changed" })
	expect(#activeTagsById["Status.Rooted"]).toBe(1)
	expect(activeTagsById["Status.Rooted"][1].duration).toBeNil()
	expect(activeTagsById["Status.Rooted"][1].remainingDuration).toBeNil()
end)

it("uses explicit duration over default duration when AddTag creates a new instance", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
		duration = 9,
	})

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(activeTagsById["Status.Stunned"][1].duration).toBe(9)
	expect(activeTagsById["Status.Stunned"][1].remainingDuration).toBe(9)
end)

it("uses the tag default duration when AddTag is called without an explicit duration", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(activeTagsById["Status.Stunned"][1].duration).toBe(1.5)
	expect(activeTagsById["Status.Stunned"][1].remainingDuration).toBe(1.5)
end)

it("leaves Ignore tags unchanged and fires no mutation events on reapply", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)
	local eventCount: number = 0

	controller.OnTagAdded:Connect(function()
		eventCount += 1
	end)

	controller.OnTagChanged:Connect(function()
		eventCount += 1
	end)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.Rooted")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()
	expect(eventCount).toBe(2)

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.Rooted")

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(eventCount).toBe(2)
	expect(#activeTagsById["Status.Rooted"]).toBe(1)
end)

it("refreshes an existing Refresh tag instead of creating a second instance", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)
	local eventOrder: { string } = {}

	controller.OnTagRefreshed:Connect(function()
		table.insert(eventOrder, "refreshed")
	end)

	controller.OnTagChanged:Connect(function()
		table.insert(eventOrder, "changed")
	end)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.Stunned")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()
	table.clear(eventOrder)

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.Stunned", {
		duration = 4,
	})

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(eventOrder).toEqual({ "refreshed", "changed" })
	expect(#activeTagsById["Status.Stunned"]).toBe(1)
	expect(activeTagsById["Status.Stunned"][1].duration).toBe(4)
	expect(activeTagsById["Status.Stunned"][1].remainingDuration).toBe(4)
end)

it("fires refreshed then changed when an indefinite Refresh tag is reapplied", function()
	local controller, actor = createController()
	local activeTagsById = getActiveTagsById(controller)
	local eventOrder: { string } = {}
	local rootedRefreshDefinition: TagDefinition = {
		id = "Status.RootedRefresh",
		duplicateBehavior = "Refresh",
		visibility = "ServerOnly",
	}

	controller.OnTagRefreshed:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "refreshed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.RootedRefresh")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.RootedRefresh")
	end)

	TagRegistry._resetForTests()
	local loaded: boolean, loadReason: string? = TagRegistry.Load({ rootedRefreshDefinition })
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.RootedRefresh")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()
	table.clear(eventOrder)

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.RootedRefresh")

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(eventOrder).toEqual({ "refreshed", "changed" })
	expect(#activeTagsById["Status.RootedRefresh"]).toBe(1)
	expect(activeTagsById["Status.RootedRefresh"][1].duration).toBeNil()
	expect(activeTagsById["Status.RootedRefresh"][1].remainingDuration).toBeNil()
end)

it("prefers refreshing a finite stack instance over an indefinite one at maxStacks", function()
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(StackWithoutDefaultDurationCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor = ActorEntity.new()
	local controller = TagController.new(actor)
	local activeTagsById = getActiveTagsById(controller)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.StackIndefinite")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.StackIndefinite", { duration = 5 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local refreshed: boolean, refreshReason: string? = controller:AddTag("Buff.StackIndefinite", { duration = 9 })
	expect(refreshed).toBe(true)
	expect(refreshReason).toBeNil()

	local instances = activeTagsById["Buff.StackIndefinite"]
	expect(#instances).toBe(2)
	expect(instances[1].duration).toBeNil()
	expect(instances[1].remainingDuration).toBeNil()
	expect(instances[2].duration).toBe(9)
	expect(instances[2].remainingDuration).toBe(9)
end)

it("refreshes the lowest-remaining oldest stack instance when reapplied at maxStacks", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	local beforeRefreshInstances = activeTagsById["Buff.Sprint"]
	expect(#beforeRefreshInstances).toBe(3)
	expect(beforeRefreshInstances[1].appliedOrder).toBe(0)
	expect(beforeRefreshInstances[2].appliedOrder).toBe(1)
	expect(beforeRefreshInstances[3].appliedOrder).toBe(2)

	local added: boolean, reason: string? = controller:AddTag("Buff.Sprint", {
		duration = 10,
	})

	expect(added).toBe(true)
	expect(reason).toBeNil()

	local afterRefreshInstances = activeTagsById["Buff.Sprint"]
	expect(#afterRefreshInstances).toBe(3)
	expect(afterRefreshInstances[1].duration).toBe(8)
	expect(afterRefreshInstances[2].duration).toBe(10)
	expect(afterRefreshInstances[2].remainingDuration).toBe(10)
	expect(afterRefreshInstances[2].appliedOrder).toBe(1)
	expect(afterRefreshInstances[3].duration).toBe(3)
end)

it("uses oldest applied order as the tie-breaker when equal remaining durations are stored out of order", function()
	local controller = createController()
	local activeTagsById = getActiveTagsById(controller)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	activeTagsById["Buff.Sprint"][1].appliedOrder = 5
	activeTagsById["Buff.Sprint"][2].appliedOrder = 4
	activeTagsById["Buff.Sprint"][3].appliedOrder = 0

	local refreshed: boolean, refreshReason: string? = controller:AddTag("Buff.Sprint", { duration = 10 })

	expect(refreshed).toBe(true)
	expect(refreshReason).toBeNil()
	expect(activeTagsById["Buff.Sprint"][1].duration).toBe(3)
	expect(activeTagsById["Buff.Sprint"][2].duration).toBe(3)
	expect(activeTagsById["Buff.Sprint"][3].duration).toBe(10)
	expect(activeTagsById["Buff.Sprint"][3].remainingDuration).toBe(10)
end)

it("returns false with a stable error when stack tag instance initialization does not persist", function()
	local controller = createController()
	local controllerInternal = (controller :: unknown) :: any

	controllerInternal._activeTagsById = setmetatable({}, {
		__index = function()
			return nil
		end,
		__newindex = function()
			return
		end,
	})

	local added: boolean, reason: string? = controller:AddTag("Buff.Sprint")

	expect(added).toBe(false)
	expect(reason).toBe("TagActiveInstancesInitFailed:Buff.Sprint")
end)

it("Destroy clears active tag state and remains a no-op when called again", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Rooted")
	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(#getActiveTagsById(controller)["Status.Rooted"]).toBe(1)

	controller:Destroy()
	local firstRemainingKey: string? = next(getActiveTagsById(controller))
	expect(firstRemainingKey).toBeNil()

	controller:Destroy()
	local secondRemainingKey: string? = next(getActiveTagsById(controller))
	expect(secondRemainingKey).toBeNil()
end)
