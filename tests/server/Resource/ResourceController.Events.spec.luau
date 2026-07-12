--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController
type ResourceController = ResourceTypes.ResourceController
type ResourceChange = ResourceTypes.ResourceChange
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ResourceControllerTestUtils = require(script.Parent.Parent.Utils.Resource.ResourceControllerTestUtils)

local function createActorWithPropertyController(): (Actor, PropertyController)
	return ResourceControllerTestUtils.createActorWithPropertyController()
end

local function resetAndLoadDefinitions(definitions: { ResourceDefinition }): ()
	ResourceControllerTestUtils.resetAndLoadDefinitions(definitions)
end

it("fires OnResourceAdded on successful add without firing OnResourceChanged", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Guard",
			max = {
				value = 40,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addedCount: number = 0
	local addedActor: Actor? = nil
	local addedResourceId: string? = nil
	local changedCount: number = 0

	local addedConnection = resourceController.OnResourceAdded:Connect(function(eventActor: Actor, resourceId: string)
		addedCount += 1
		addedActor = eventActor
		addedResourceId = resourceId
	end)
	local changedConnection = resourceController.OnResourceChanged:Connect(function(_change: ResourceChange)
		changedCount += 1
	end)

	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Guard")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	for _index: number = 1, 30 do
		if addedCount == 1 then
			break
		end
		task.wait()
	end

	expect(addedCount).toBe(1)
	expect(addedActor).toBe(actor)
	expect(addedResourceId).toBe("Resource.Guard")

	task.wait()
	task.wait()
	expect(changedCount).toBe(0)

	local duplicateOk: boolean, duplicateReason: string? = resourceController:AddResource("Resource.Guard")

	expect(duplicateOk).toBe(false)
	expect(duplicateReason).toBe("ResourceAlreadyAssigned")

	task.wait()
	task.wait()
	expect(addedCount).toBe(1)
	expect(changedCount).toBe(0)

	addedConnection:Disconnect()
	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("fires OnResourceChanged only when SetCurrent changes the final current value", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 5,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve")
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	local setCurrentOk: boolean, setCurrentReason: string? = resourceController:SetCurrent("Resource.Resolve", 20)

	expect(setCurrentOk).toBe(true)
	expect(setCurrentReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 1 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(1)
	expect(changes[1]).toEqual({
		actor = actor,
		resourceId = "Resource.Resolve",
		currentOldValue = 30,
		currentNewValue = 20,
		minOldValue = 5,
		minNewValue = 5,
		maxOldValue = 30,
		maxNewValue = 30,
	})

	local sameValueOk: boolean, sameValueReason: string? = resourceController:SetCurrent("Resource.Resolve", 20)

	expect(sameValueOk).toBe(true)
	expect(sameValueReason).toBeNil()

	task.wait()
	task.wait()
	expect(#changes).toBe(1)

	local clampChangeOk: boolean, clampChangeReason: string? = resourceController:SetCurrent("Resource.Resolve", 999)

	expect(clampChangeOk).toBe(true)
	expect(clampChangeReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 2 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(2)
	expect(changes[2]).toEqual({
		actor = actor,
		resourceId = "Resource.Resolve",
		currentOldValue = 20,
		currentNewValue = 30,
		minOldValue = 5,
		minNewValue = 5,
		maxOldValue = 30,
		maxNewValue = 30,
	})

	local noOpClampOk: boolean, noOpClampReason: string? = resourceController:SetCurrent("Resource.Resolve", 999)
	local invalidOk: boolean, invalidReason: string? = resourceController:SetCurrent("Resource.Resolve", "boom" :: any)

	expect(noOpClampOk).toBe(true)
	expect(noOpClampReason).toBeNil()
	expect(invalidOk).toBe(false)
	expect(invalidReason).toBe("InvalidResourceValue")

	task.wait()
	task.wait()
	expect(#changes).toBe(2)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("fires OnResourceChanged for Spend only when current value changes", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	local spendOk: boolean, spendReason: string? = resourceController:Spend("Resource.Resolve", 5)

	expect(spendOk).toBe(true)
	expect(spendReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 1 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(1)
	expect(changes[1].currentOldValue).toBe(15)
	expect(changes[1].currentNewValue).toBe(10)
	expect(changes[1].resourceId).toBe("Resource.Resolve")

	local insufficientOk: boolean, insufficientReason: string? = resourceController:Spend("Resource.Resolve", 1)

	expect(insufficientOk).toBe(false)
	expect(insufficientReason).toBe("InsufficientResourceValue")

	task.wait()
	task.wait()
	expect(#changes).toBe(1)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("fires OnResourceChanged for Restore only when current value changes", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	local restoreOk: boolean, restoreReason: string? = resourceController:Restore("Resource.Resolve", 5)

	expect(restoreOk).toBe(true)
	expect(restoreReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 1 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(1)
	expect(changes[1].currentOldValue).toBe(15)
	expect(changes[1].currentNewValue).toBe(20)
	expect(changes[1].resourceId).toBe("Resource.Resolve")

	local clampOk: boolean, clampReason: string? = resourceController:Restore("Resource.Resolve", 50)

	expect(clampOk).toBe(true)
	expect(clampReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 2 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(2)
	expect(changes[2].currentOldValue).toBe(20)
	expect(changes[2].currentNewValue).toBe(30)

	local noOpOk: boolean, noOpReason: string? = resourceController:Restore("Resource.Resolve", 1)

	expect(noOpOk).toBe(true)
	expect(noOpReason).toBeNil()

	task.wait()
	task.wait()
	expect(#changes).toBe(2)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("fires OnResourceChanged for Drain only when current value changes", function()
	resetAndLoadDefinitions({
		{
			id = "Resource.Resolve",
			min = {
				value = 10,
			},
			max = {
				value = 30,
			},
			visibility = "ServerOnly",
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Resolve", 15)
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	local drainOk: boolean, drainReason: string? = resourceController:Drain("Resource.Resolve", 3)

	expect(drainOk).toBe(true)
	expect(drainReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 1 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(1)
	expect(changes[1].currentOldValue).toBe(15)
	expect(changes[1].currentNewValue).toBe(12)
	expect(changes[1].resourceId).toBe("Resource.Resolve")

	local clampOk: boolean, clampReason: string? = resourceController:Drain("Resource.Resolve", 50)

	expect(clampOk).toBe(true)
	expect(clampReason).toBeNil()

	for _index: number = 1, 30 do
		if #changes == 2 then
			break
		end
		task.wait()
	end

	expect(#changes).toBe(2)
	expect(changes[2].currentOldValue).toBe(12)
	expect(changes[2].currentNewValue).toBe(10)

	local noOpOk: boolean, noOpReason: string? = resourceController:Drain("Resource.Resolve", 1)

	expect(noOpOk).toBe(true)
	expect(noOpReason).toBeNil()

	task.wait()
	task.wait()
	expect(#changes).toBe(2)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("Destroy tears down resource event surfaces", function()
	local actor: Actor, propertyController: PropertyController = createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)

	resourceController:Destroy()

	expect(function()
		resourceController.OnResourceAdded:Connect(function() end)
	end).toThrow()

	expect(function()
		resourceController.OnResourceChanged:Connect(function() end)
	end).toThrow()

	expect(function()
		resourceController.OnResourceChanged:Wait()
	end).toThrow()

	propertyController:Destroy()
end)
