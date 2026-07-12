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
type ResourceChange = ResourceTypes.ResourceChange
type ResourceController = ResourceTypes.ResourceController
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ResourceControllerTestUtils = require(script.Parent.Parent.Utils.Resource.ResourceControllerTestUtils)

local function runWithManualAutomaticStepping(callback: () -> ()): ()
	ResourceControllerModule._setAutomaticSteppingEnabledForTests(false)

	local success: boolean, failureReason: unknown = pcall(callback)

	ResourceControllerModule._setAutomaticSteppingEnabledForTests(true)

	if not success then
		error(tostring(failureReason))
	end
end

it("automatically restores enabled actors at the fixed ten hertz interval", function()
	ResourceControllerTestUtils.resetAndLoadDefinitions({
		{
			id = "Resource.Stamina",
			max = {
				value = 100,
			},
			initialValue = 0,
			visibility = "ServerOnly",
			regen = {
				rate = {
					value = 10,
				},
			},
		},
	} :: { ResourceDefinition })

	local actor: Actor, propertyController: PropertyController =
		ResourceControllerTestUtils.createActorWithPropertyController()
	local resourceController: ResourceController = ResourceControllerModule.new(actor)
	local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Stamina")
	local changes: { ResourceChange } = {}

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local changedConnection = resourceController.OnResourceChanged:Connect(function(change: ResourceChange)
		table.insert(changes, change)
	end)

	actor.enabled = true
	expect(ResourceControllerTestUtils.waitUntil(function(): boolean
		return #changes >= 1
	end, 60)).toBe(true)
	expect(changes[1].currentOldValue).toBe(0)
	expect(changes[1].currentNewValue).toBe(1)

	changedConnection:Disconnect()
	resourceController:Destroy()
	propertyController:Destroy()
end)

it("skips disabled actors until they become enabled", function()
	runWithManualAutomaticStepping(function()
		ResourceControllerTestUtils.resetAndLoadDefinitions({
			{
				id = "Resource.Focus",
				max = {
					value = 100,
				},
				initialValue = 10,
				visibility = "ServerOnly",
				regen = {
					rate = {
						value = 4,
					},
				},
			},
		} :: { ResourceDefinition })

		local actor: Actor, propertyController: PropertyController =
			ResourceControllerTestUtils.createActorWithPropertyController()
		local resourceController: ResourceController = ResourceControllerModule.new(actor)
		local addOk: boolean, addReason: string? = resourceController:AddResource("Resource.Focus")

		expect(addOk).toBe(true)
		expect(addReason).toBeNil()

		ResourceControllerModule.Step(0)
		expect(resourceController:GetCurrent("Resource.Focus")).toBe(10)

		ResourceControllerModule.Step(0.5)
		expect(resourceController:GetCurrent("Resource.Focus")).toBe(10)

		actor.enabled = true
		ResourceControllerModule.Step(0.5)
		expect(resourceController:GetCurrent("Resource.Focus")).toBe(12)

		resourceController:Destroy()
		propertyController:Destroy()
	end)
end)

it("dispatches only to regen controllers and unregisters them on Destroy", function()
	runWithManualAutomaticStepping(function()
		ResourceControllerTestUtils.resetAndLoadDefinitions({
			{
				id = "Resource.Mana",
				max = {
					value = 100,
				},
				visibility = "ServerOnly",
				regen = {
					rate = {
						value = 5,
					},
				},
			},
			{
				id = "Resource.Guard",
				max = {
					value = 100,
				},
				visibility = "ServerOnly",
			},
		} :: { ResourceDefinition })

		local regenActor: Actor, regenPropertyController: PropertyController =
			ResourceControllerTestUtils.createActorWithPropertyController()
		local staticActor: Actor, staticPropertyController: PropertyController =
			ResourceControllerTestUtils.createActorWithPropertyController()
		local regenController: ResourceController = ResourceControllerModule.new(regenActor)
		local staticController: ResourceController = ResourceControllerModule.new(staticActor)
		local addRegenOk: boolean, addRegenReason: string? = regenController:AddResource("Resource.Mana")
		local addStaticOk: boolean, addStaticReason: string? = staticController:AddResource("Resource.Guard")
		local regenStepCount: number = 0
		local staticStepCount: number = 0
		local regenControllerProbe: any = regenController
		local staticControllerProbe: any = staticController

		expect(addRegenOk).toBe(true)
		expect(addRegenReason).toBeNil()
		expect(addStaticOk).toBe(true)
		expect(addStaticReason).toBeNil()
		regenControllerProbe.Step = function(_self: any, _deltaTime: number): ()
			regenStepCount += 1
		end
		staticControllerProbe.Step = function(_self: any, _deltaTime: number): ()
			staticStepCount += 1
		end

		regenActor.enabled = true
		staticActor.enabled = true
		ResourceControllerModule.Step(0.1)

		expect(regenStepCount).toBe(1)
		expect(staticStepCount).toBe(0)

		regenController:Destroy()
		ResourceControllerModule.Step(0.1)

		expect(regenStepCount).toBe(1)
		expect(staticStepCount).toBe(0)

		staticController:Destroy()
		regenPropertyController:Destroy()
		staticPropertyController:Destroy()
	end)
end)
