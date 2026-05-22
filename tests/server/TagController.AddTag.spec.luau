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
type ActiveTagSnapshot = TagTypes.ActiveTagSnapshot
type TagInstanceSnapshot = TagTypes.TagInstanceSnapshot

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

local RootedRefreshCatalog: { TagDefinition } = {
	{
		id = "Status.RootedRefresh",
		duplicateBehavior = "Refresh",
		visibility = "ServerOnly",
	},
}

local UncappedStackCatalog: { TagDefinition } = {
	{
		id = "Buff.Endurance",
		defaultDuration = 12,
		duplicateBehavior = "Stack",
		visibility = "ClientVisible",
	},
}

local function createControllerWithCatalog(catalog: { TagDefinition }): (TagControllerType, any)
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(catalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor = ActorEntity.new()
	local controller: TagControllerType = TagController.new(actor)

	return controller, actor
end

local function createController(): (TagControllerType, any)
	return createControllerWithCatalog(TestCatalog)
end

it("returns false with a stable error when AddTag receives an unknown tag id", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Unknown")

	expect(added).toBe(false)
	expect(reason).toBe("UnknownTagId:Status.Unknown")
end)

it("HasTag is false before add and true after add", function()
	local controller = createController()

	expect(controller:HasTag("Status.Rooted")).toBe(false)

	local added: boolean, reason: string? = controller:AddTag("Status.Rooted")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(controller:HasTag("Status.Rooted")).toBe(true)
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
	local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()
	local tagInstances: { TagInstanceSnapshot } = controller:GetTagInstances("Status.Rooted")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(eventOrder).toEqual({ "added", "changed" })
	expect(activeTags).toEqual({
		{
			tagId = "Status.Rooted",
			stackCount = 1,
		},
	})
	expect(tagInstances).toEqual({
		{
			tagId = "Status.Rooted",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
	})
end)

it("uses explicit duration over default duration when AddTag creates a new instance", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
		duration = 9,
	})

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 9,
			remainingDuration = 9,
			appliedOrder = 0,
		},
	})
end)

it("uses the tag default duration when AddTag is called without an explicit duration", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 1.5,
			remainingDuration = 1.5,
			appliedOrder = 0,
		},
	})
end)

it("is indefinite when neither explicit nor default duration exists", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Rooted")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({
		{
			tagId = "Status.Rooted",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
	})
end)

it("leaves Ignore tags unchanged and fires no mutation events on reapply", function()
	local controller = createController()
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
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({
		{
			tagId = "Status.Rooted",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
	})
end)

it("does not retrofit explicit duration onto an active Ignore tag when reapplied", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.Rooted")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.Rooted", {
		duration = 7,
	})

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({
		{
			tagId = "Status.Rooted",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
	})
end)

it("creates a first active instance and fires added then changed for a Refresh tag", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	controller.OnTagAdded:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "added")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Stunned")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Status.Stunned")
	end)

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned")

	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(eventOrder).toEqual({ "added", "changed" })
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 1.5,
			remainingDuration = 1.5,
			appliedOrder = 0,
		},
	})
end)

it("refreshes an existing Refresh tag instead of creating a second instance", function()
	local controller = createController()
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
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 4,
			remainingDuration = 4,
			appliedOrder = 0,
		},
	})
end)

it("resolves refresh duration again on reapply instead of preserving the prior explicit duration", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.Stunned", {
		duration = 9,
	})
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.Stunned")

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 1.5,
			remainingDuration = 1.5,
			appliedOrder = 0,
		},
	})
end)

it("fires refreshed then changed when an indefinite Refresh tag is reapplied", function()
	local controller, actor = createControllerWithCatalog(RootedRefreshCatalog)
	local eventOrder: { string } = {}

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

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Status.RootedRefresh")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()
	table.clear(eventOrder)

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Status.RootedRefresh")

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(eventOrder).toEqual({ "refreshed", "changed" })
	expect(controller:GetTagInstances("Status.RootedRefresh")).toEqual({
		{
			tagId = "Status.RootedRefresh",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
	})
end)

it("GetActiveTags returns aggregated entries rather than one entry per stack instance", function()
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

	local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()

	expect(#activeTags).toBe(1)
	expect(activeTags[1].tagId).toBe("Buff.Sprint")
	expect(activeTags[1].stackCount).toBe(3)
	expect(activeTags[1].remainingDuration).toBe(8)
end)

it("GetActiveTags preserves oldest-applied tag ordering across different active tags", function()
	local controller = createController()

	local rootedAdded: boolean, rootedReason: string? = controller:AddTag("Status.Rooted")
	expect(rootedAdded).toBe(true)
	expect(rootedReason).toBeNil()

	local stunnedAdded: boolean, stunnedReason: string? = controller:AddTag("Status.Stunned")
	expect(stunnedAdded).toBe(true)
	expect(stunnedReason).toBeNil()

	local sprintAdded: boolean, sprintReason: string? = controller:AddTag("Buff.Sprint", {
		duration = 8,
	})
	expect(sprintAdded).toBe(true)
	expect(sprintReason).toBeNil()

	local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()

	expect(#activeTags).toBe(3)
	expect(activeTags[1].tagId).toBe("Status.Rooted")
	expect(activeTags[1].stackCount).toBe(1)
	expect(activeTags[1].remainingDuration).toBeNil()
	expect(activeTags[2].tagId).toBe("Status.Stunned")
	expect(activeTags[2].stackCount).toBe(1)
	expect(activeTags[2].remainingDuration).toBe(1.5)
	expect(activeTags[3].tagId).toBe("Buff.Sprint")
	expect(activeTags[3].stackCount).toBe(1)
	expect(activeTags[3].remainingDuration).toBe(8)
end)

it("GetTagInstances returns detailed instances for an active tag", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({
		{
			tagId = "Buff.Sprint",
			duration = 8,
			remainingDuration = 8,
			appliedOrder = 0,
		},
		{
			tagId = "Buff.Sprint",
			duration = 4,
			remainingDuration = 4,
			appliedOrder = 1,
		},
	})
end)

it("GetTagInstances returns empty for a non-active tag", function()
	local controller = createController()

	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({})
end)

it("prefers refreshing a finite stack instance over an indefinite one at maxStacks", function()
	local controller = createControllerWithCatalog(StackWithoutDefaultDurationCatalog)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.StackIndefinite")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.StackIndefinite", { duration = 5 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local refreshed: boolean, refreshReason: string? = controller:AddTag("Buff.StackIndefinite", { duration = 9 })
	expect(refreshed).toBe(true)
	expect(refreshReason).toBeNil()

	expect(controller:GetTagInstances("Buff.StackIndefinite")).toEqual({
		{
			tagId = "Buff.StackIndefinite",
			duration = nil,
			remainingDuration = nil,
			appliedOrder = 0,
		},
		{
			tagId = "Buff.StackIndefinite",
			duration = 9,
			remainingDuration = 9,
			appliedOrder = 1,
		},
	})
end)

it("fires added then changed for each Stack apply while below maxStacks", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	controller.OnTagAdded:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "added:" .. changedTagId)
		expect(changedActor).toBe(actor)
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed:" .. changedTagId)
		expect(changedActor).toBe(actor)
	end)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })

	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()
	expect(eventOrder).toEqual({
		"added:Buff.Sprint",
		"changed:Buff.Sprint",
		"added:Buff.Sprint",
		"changed:Buff.Sprint",
	})
end)

it("fires refreshed then changed without firing added when a stacked tag is reapplied at maxStacks", function()
	local controller, actor = createController()
	local eventOrder: { string } = {}

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 4 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 2 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	controller.OnTagAdded:Connect(function()
		table.insert(eventOrder, "added")
	end)

	controller.OnTagRefreshed:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "refreshed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Buff.Sprint")
	end)

	controller.OnTagChanged:Connect(function(changedActor, changedTagId)
		table.insert(eventOrder, "changed")
		expect(changedActor).toBe(actor)
		expect(changedTagId).toBe("Buff.Sprint")
	end)

	local refreshed: boolean, refreshReason: string? = controller:AddTag("Buff.Sprint", {
		duration = 10,
	})

	expect(refreshed).toBe(true)
	expect(refreshReason).toBeNil()
	expect(eventOrder).toEqual({ "refreshed", "changed" })
end)

it("refreshes the lowest-remaining oldest stack instance when reapplied at maxStacks", function()
	local controller = createController()

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Sprint", { duration = 8 })
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Sprint", { duration = 3 })
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	local refreshed: boolean, refreshReason: string? = controller:AddTag("Buff.Sprint", {
		duration = 10,
	})

	expect(refreshed).toBe(true)
	expect(refreshReason).toBeNil()
	expect(controller:GetTagInstances("Buff.Sprint")).toEqual({
		{
			tagId = "Buff.Sprint",
			duration = 8,
			remainingDuration = 8,
			appliedOrder = 0,
		},
		{
			tagId = "Buff.Sprint",
			duration = 10,
			remainingDuration = 10,
			appliedOrder = 1,
		},
		{
			tagId = "Buff.Sprint",
			duration = 3,
			remainingDuration = 3,
			appliedOrder = 2,
		},
	})
end)

it("allows uncapped Stack tags to keep creating new active instances", function()
	local controller = createControllerWithCatalog(UncappedStackCatalog)

	local firstAdded: boolean, firstReason: string? = controller:AddTag("Buff.Endurance")
	expect(firstAdded).toBe(true)
	expect(firstReason).toBeNil()

	local secondAdded: boolean, secondReason: string? = controller:AddTag("Buff.Endurance")
	expect(secondAdded).toBe(true)
	expect(secondReason).toBeNil()

	local thirdAdded: boolean, thirdReason: string? = controller:AddTag("Buff.Endurance")
	expect(thirdAdded).toBe(true)
	expect(thirdReason).toBeNil()

	local activeTags: { ActiveTagSnapshot } = controller:GetActiveTags()

	expect(#activeTags).toBe(1)
	expect(activeTags[1].tagId).toBe("Buff.Endurance")
	expect(activeTags[1].stackCount).toBe(3)
	expect(activeTags[1].remainingDuration).toBe(12)
	expect(controller:GetTagInstances("Buff.Endurance")).toEqual({
		{
			tagId = "Buff.Endurance",
			duration = 12,
			remainingDuration = 12,
			appliedOrder = 0,
		},
		{
			tagId = "Buff.Endurance",
			duration = 12,
			remainingDuration = 12,
			appliedOrder = 1,
		},
		{
			tagId = "Buff.Endurance",
			duration = 12,
			remainingDuration = 12,
			appliedOrder = 2,
		},
	})
end)

it("no expiry or removal occurs merely because duration metadata exists", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Stunned", {
		duration = 0.05,
	})

	expect(added).toBe(true)
	expect(reason).toBeNil()

	task.wait(0.1)

	expect(controller:HasTag("Status.Stunned")).toBe(true)
	expect(controller:GetTagInstances("Status.Stunned")).toEqual({
		{
			tagId = "Status.Stunned",
			duration = 0.05,
			remainingDuration = 0.05,
			appliedOrder = 0,
		},
	})
end)

it("Destroy clears active tag state and remains a no-op when called again", function()
	local controller = createController()

	local added: boolean, reason: string? = controller:AddTag("Status.Rooted")
	expect(added).toBe(true)
	expect(reason).toBeNil()
	expect(controller:HasTag("Status.Rooted")).toBe(true)

	controller:Destroy()
	expect(controller:HasTag("Status.Rooted")).toBe(false)
	expect(controller:GetActiveTags()).toEqual({})
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({})

	controller:Destroy()
	expect(controller:HasTag("Status.Rooted")).toBe(false)
	expect(controller:GetActiveTags()).toEqual({})
	expect(controller:GetTagInstances("Status.Rooted")).toEqual({})
end)
