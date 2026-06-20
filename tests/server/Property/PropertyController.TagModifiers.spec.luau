--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController
type PropertyChange = PropertyTypes.PropertyChange
type TagControllerType = TagTypes.TagController
type TagDefinition = TagTypes.TagDefinition

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local PropertyControllerModule = require(KRF.server.Property.PropertyController)
local TagControllerModule = require(KRF.server.Tags.TagController)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local TagTestUtils: any = script.Parent.Parent.Utils.Tags

local MixedTagCatalog: { TagDefinition } = require(TagTestUtils.MixedTagCatalog) :: { TagDefinition }
local ValidPropertyModifierCatalog: { TagDefinition } =
	require(TagTestUtils.ValidPropertyModifierCatalog) :: { TagDefinition }

local function createControllerWithCatalog(
	catalog: { TagDefinition },
	shouldEnableActor: boolean?
): (Actor, TagControllerType, PropertyController)
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(catalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor: Actor = ActorEntity.new()
	actor.enabled = shouldEnableActor == true

	local tagController: TagControllerType = TagControllerModule.new(actor)
	local setTagControllerOk: boolean = actor:SetController("TagController", tagController)
	expect(setTagControllerOk).toBe(true)

	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	return actor, tagController, propertyController
end

local function destroyControllers(tagController: TagControllerType, propertyController: PropertyController): ()
	propertyController:Destroy()
	tagController:Destroy()
end

local function runWithManualStepping(callback: () -> ())
	TagControllerModule._setAutomaticSteppingEnabledForTests(false)

	local success: boolean, failureReason: unknown = pcall(callback)

	TagControllerModule._setAutomaticSteppingEnabledForTests(true)

	if not success then
		error(tostring(failureReason))
	end
end

it("recomputes built-in WalkSpeed on tag add and fires resolved then umbrella events without a base event", function()
	local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(ValidPropertyModifierCatalog)
	local baseEventCount: number = 0
	local eventOrder: { string } = {}
	local umbrellaPayload: PropertyChange? = nil

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(function()
		baseEventCount += 1
	end)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "resolved")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("WalkSpeed")
			expect(oldValue).toBe(16)
			expect(newValue).toBeCloseTo(25.3, 5)
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		table.insert(eventOrder, "umbrella")
		umbrellaPayload = change
	end)

	local addOk: boolean, addReason: string? = tagController:AddTag("Buff.Sprint")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(baseEventCount).toBe(0)
	expect(eventOrder).toEqual({ "resolved", "umbrella" })
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBeCloseTo(25.3, 5)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("recomputes resolved WalkSpeed from active normal modifiers when the base value is written", function()
	local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(ValidPropertyModifierCatalog)
	local eventOrder: { string } = {}
	local baseOldValue: number? = nil
	local baseNewValue: number? = nil
	local resolvedOldValue: number? = nil
	local resolvedNewValue: number? = nil
	local umbrellaPayload: PropertyChange? = nil

	tagController:AddTag("Buff.Sprint")

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "base")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("WalkSpeed")
			baseOldValue = oldValue
			baseNewValue = newValue
		end
	)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "resolved")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("WalkSpeed")
			resolvedOldValue = oldValue
			resolvedNewValue = newValue
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		table.insert(eventOrder, "umbrella")
		umbrellaPayload = change
	end)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("WalkSpeed", 20)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(eventOrder).toEqual({ "base", "resolved", "umbrella" })
	expect(propertyController:GetBaseProperty("WalkSpeed")).toBe(20)
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(29.9, 5)
	expect(baseOldValue).toBe(16)
	expect(baseNewValue).toBe(20)
	expect(resolvedOldValue).toBeCloseTo(25.3, 5)
	expect(resolvedNewValue).toBeCloseTo(29.9, 5)
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(20)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBeCloseTo(25.3, 5)
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBeCloseTo(29.9, 5)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("recomputes built-in WalkSpeed and JumpPower from active set modifiers", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)

	local addOk: boolean, addReason: string? = tagController:AddTag("Status.Stunned")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(0)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(0)

	destroyControllers(tagController, propertyController)
end)

it(
	"fires base and umbrella events without a resolved event when an active set keeps the final value unchanged",
	function()
		local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
			createControllerWithCatalog(ValidPropertyModifierCatalog)
		local eventOrder: { string } = {}
		local baseOldValue: number? = nil
		local baseNewValue: number? = nil
		local resolvedEventCount: number = 0
		local umbrellaPayload: PropertyChange? = nil

		tagController:AddTag("Status.Stunned")

		local baseConnection = propertyController.OnBasePropertyChanged:Connect(
			function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
				table.insert(eventOrder, "base")
				expect(eventActor).toBe(actor)
				expect(propertyName).toBe("WalkSpeed")
				baseOldValue = oldValue
				baseNewValue = newValue
			end
		)
		local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
			resolvedEventCount += 1
		end)
		local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
			table.insert(eventOrder, "umbrella")
			umbrellaPayload = change
		end)

		local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("WalkSpeed", 24)

		expect(setOk).toBe(true)
		expect(setReason).toBeNil()
		expect(eventOrder).toEqual({ "base", "umbrella" })
		expect(resolvedEventCount).toBe(0)
		expect(propertyController:GetBaseProperty("WalkSpeed")).toBe(24)
		expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(0)
		expect(baseOldValue).toBe(16)
		expect(baseNewValue).toBe(24)
		expect(umbrellaPayload).never.toBeNil()
		expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBe(16)
		expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(24)
		expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBe(0)
		expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBe(0)

		baseConnection:Disconnect()
		resolvedConnection:Disconnect()
		umbrellaConnection:Disconnect()
		destroyControllers(tagController, propertyController)
	end
)

it("applies pre-existing active tags when the property controller is created after the tag controller", function()
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(ValidPropertyModifierCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local actor: Actor = ActorEntity.new()
	local tagController: TagControllerType = TagControllerModule.new(actor)
	local setTagControllerOk: boolean = actor:SetController("TagController", tagController)
	expect(setTagControllerOk).toBe(true)

	local addOk: boolean, addReason: string? = tagController:AddTag("Buff.Sprint")
	expect(addOk).toBe(true)
	expect(addReason).toBeNil()

	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	expect(propertyController:GetBaseProperty("WalkSpeed")).toBe(16)
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)

	destroyControllers(tagController, propertyController)
end)

it(
	"does not create a user-defined property when a custom-property-only tag applies before a base value exists",
	function()
		local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
			createControllerWithCatalog(MixedTagCatalog)
		local resolvedEventCount: number = 0
		local umbrellaEventCount: number = 0

		local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
			resolvedEventCount += 1
		end)
		local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function()
			umbrellaEventCount += 1
		end)

		local addOk: boolean, addReason: string? = tagController:AddTag("Status.OnFire")

		expect(addOk).toBe(true)
		expect(addReason).toBeNil()
		expect(propertyController:HasProperty("HealingReceived")).toBe(false)
		expect(propertyController:GetBaseProperty("HealingReceived")).toBeNil()
		expect(propertyController:GetResolvedProperty("HealingReceived")).toBeNil()
		expect(resolvedEventCount).toBe(0)
		expect(umbrellaEventCount).toBe(0)
		expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(16)

		resolvedConnection:Disconnect()
		umbrellaConnection:Disconnect()
		destroyControllers(tagController, propertyController)
	end
)

it("applies an already-active custom-property modifier when the property is created later", function()
	local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)
	local eventOrder: { string } = {}
	local umbrellaPayload: PropertyChange? = nil

	tagController:AddTag("Status.OnFire")

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "base")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("HealingReceived")
			expect(oldValue).toBeNil()
			expect(newValue).toBe(100)
		end
	)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "resolved")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("HealingReceived")
			expect(oldValue).toBeNil()
			expect(newValue).toBe(75)
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		table.insert(eventOrder, "umbrella")
		umbrellaPayload = change
	end)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("HealingReceived", 100)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(eventOrder).toEqual({ "base", "resolved", "umbrella" })
	expect(propertyController:HasProperty("HealingReceived")).toBe(true)
	expect(propertyController:GetBaseProperty("HealingReceived")).toBe(100)
	expect(propertyController:GetResolvedProperty("HealingReceived")).toBe(75)
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBeNil()
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(100)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBeNil()
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBe(75)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("supports built-in and user-defined numeric properties coexisting under the same active tag", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("DashCostMultiplier", 1.5)
	expect(setOk).toBe(true)
	expect(setReason).toBeNil()

	local addOk: boolean, addReason: string? = tagController:AddTag("Buff.Sprint")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(50)
	expect(propertyController:GetResolvedProperty("DashCostMultiplier")).toBeCloseTo(1.2, 5)

	local snapshot: { [string]: number } = propertyController:GetResolvedProperties()

	expect(snapshot.WalkSpeed).toBeCloseTo(25.3, 5)
	expect(snapshot.JumpPower).toBe(50)
	expect(snapshot.DashCostMultiplier).toBeCloseTo(1.2, 5)

	destroyControllers(tagController, propertyController)
end)

it("recomputes through the normal modifier path when removing the final active set modifier", function()
	local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)
	local resolvedChanges: { { propertyName: string, oldValue: number?, newValue: number } } = {}

	tagController:AddTag("Buff.Sprint")
	tagController:AddTag("Status.Stunned")

	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			expect(eventActor).toBe(actor)
			table.insert(resolvedChanges, {
				propertyName = propertyName,
				oldValue = oldValue,
				newValue = newValue,
			})
		end
	)

	local removeOk: boolean, removeReason: string? = tagController:RemoveTag("Status.Stunned")

	expect(removeOk).toBe(true)
	expect(removeReason).toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(50)
	expect(#resolvedChanges).toBe(2)
	expect(resolvedChanges[1].propertyName).toBe("JumpPower")
	expect(resolvedChanges[1].oldValue).toBe(0)
	expect(resolvedChanges[1].newValue).toBe(50)
	expect(resolvedChanges[2].propertyName).toBe("WalkSpeed")
	expect(resolvedChanges[2].oldValue).toBe(0)
	expect(resolvedChanges[2].newValue).toBeCloseTo(25.3, 5)

	resolvedConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("recomputes through the normal modifier path when the final active set modifier expires", function()
	runWithManualStepping(function()
		local actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
			createControllerWithCatalog(MixedTagCatalog, true)
		local resolvedChanges: { { propertyName: string, oldValue: number?, newValue: number } } = {}

		tagController:AddTag("Buff.Sprint")
		tagController:AddTag("Status.Stunned")

		local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
			function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
				expect(eventActor).toBe(actor)
				table.insert(resolvedChanges, {
					propertyName = propertyName,
					oldValue = oldValue,
					newValue = newValue,
				})
			end
		)

		TagControllerModule.Step(1.5)

		expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)
		expect(propertyController:GetResolvedProperty("JumpPower")).toBe(50)
		expect(#resolvedChanges).toBe(2)
		expect(resolvedChanges[1].propertyName).toBe("JumpPower")
		expect(resolvedChanges[1].oldValue).toBe(0)
		expect(resolvedChanges[1].newValue).toBe(50)
		expect(resolvedChanges[2].propertyName).toBe("WalkSpeed")
		expect(resolvedChanges[2].oldValue).toBe(0)
		expect(resolvedChanges[2].newValue).toBeCloseTo(25.3, 5)

		resolvedConnection:Disconnect()
		destroyControllers(tagController, propertyController)
	end)
end)

it("fires no property events when refresh recomputes but the final resolved value stays the same", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)
	local baseEventCount: number = 0
	local resolvedEventCount: number = 0
	local umbrellaEventCount: number = 0

	tagController:AddTag("Status.Stunned")

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(function()
		baseEventCount += 1
	end)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
		resolvedEventCount += 1
	end)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function()
		umbrellaEventCount += 1
	end)

	local refreshOk: boolean, refreshReason: string? = tagController:AddTag("Status.Stunned")

	expect(refreshOk).toBe(true)
	expect(refreshReason).toBeNil()
	expect(baseEventCount).toBe(0)
	expect(resolvedEventCount).toBe(0)
	expect(umbrellaEventCount).toBe(0)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it(
	"fires no property events when recomputation changes the internal path but the final resolved value stays clamped",
	function()
		local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
			createControllerWithCatalog(ValidPropertyModifierCatalog)
		local resolvedEventCount: number = 0
		local umbrellaEventCount: number = 0

		tagController:AddTag("Buff.Sprint")
		tagController:AddTag("Buff.Sprint")

		local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
			resolvedEventCount += 1
		end)
		local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function()
			umbrellaEventCount += 1
		end)

		local thirdAddOk: boolean, thirdAddReason: string? = tagController:AddTag("Buff.Sprint")

		expect(thirdAddOk).toBe(true)
		expect(thirdAddReason).toBeNil()
		expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(32)
		expect(resolvedEventCount).toBe(0)
		expect(umbrellaEventCount).toBe(0)

		resolvedConnection:Disconnect()
		umbrellaConnection:Disconnect()
		destroyControllers(tagController, propertyController)
	end
)

it("fires only when stack removal changes the final unclamped WalkSpeed", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(ValidPropertyModifierCatalog)
	local baseEventCount: number = 0
	local eventOrder: { string } = {}
	local resolvedOldValue: number? = nil
	local resolvedNewValue: number? = nil
	local umbrellaPayload: PropertyChange? = nil

	tagController:AddTag("Buff.Sprint")
	tagController:AddTag("Buff.Sprint")
	tagController:AddTag("Buff.Sprint")

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(function()
		baseEventCount += 1
	end)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(_eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "resolved")
			expect(propertyName).toBe("WalkSpeed")
			resolvedOldValue = oldValue
			resolvedNewValue = newValue
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		table.insert(eventOrder, "umbrella")
		umbrellaPayload = change
	end)

	local firstRemoveOk: boolean, firstRemoveReason: string? = tagController:RemoveSingleTag("Buff.Sprint")

	expect(firstRemoveOk).toBe(true)
	expect(firstRemoveReason).toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(32)
	expect(baseEventCount).toBe(0)
	expect(eventOrder).toEqual({})

	local secondRemoveOk: boolean, secondRemoveReason: string? = tagController:RemoveSingleTag("Buff.Sprint")

	expect(secondRemoveOk).toBe(true)
	expect(secondRemoveReason).toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBeCloseTo(25.3, 5)
	expect(baseEventCount).toBe(0)
	expect(eventOrder).toEqual({ "resolved", "umbrella" })
	expect(resolvedOldValue).toBe(32)
	expect(resolvedNewValue).toBeCloseTo(25.3, 5)
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(16)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBe(32)
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBeCloseTo(25.3, 5)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("fires no property events when a set modifier recomputes to the value already stored", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(ValidPropertyModifierCatalog)
	local baseEventCount: number = 0
	local resolvedEventCount: number = 0
	local umbrellaEventCount: number = 0

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("WalkSpeed", 0)
	expect(setOk).toBe(true)
	expect(setReason).toBeNil()

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(function()
		baseEventCount += 1
	end)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
		resolvedEventCount += 1
	end)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function()
		umbrellaEventCount += 1
	end)

	local addOk: boolean, addReason: string? = tagController:AddTag("Status.Stunned")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(baseEventCount).toBe(0)
	expect(resolvedEventCount).toBe(0)
	expect(umbrellaEventCount).toBe(0)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	destroyControllers(tagController, propertyController)
end)

it("stops emitting later property events if the controller is destroyed during a multi-property recompute", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)
	local resolvedEventCount: number = 0

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("DashCostMultiplier", 1.5)
	expect(setOk).toBe(true)
	expect(setReason).toBeNil()

	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
		resolvedEventCount += 1
		propertyController:Destroy()
	end)

	local addOk: boolean, addReason: string? = tagController:AddTag("Buff.Sprint")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(resolvedEventCount).toBe(1)

	resolvedConnection:Disconnect()
	tagController:Destroy()
end)

it("ignores later tag mutations after the property controller is destroyed", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(ValidPropertyModifierCatalog)
	local baseEventCount: number = 0
	local resolvedEventCount: number = 0
	local umbrellaEventCount: number = 0

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(function()
		baseEventCount += 1
	end)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(function()
		resolvedEventCount += 1
	end)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function()
		umbrellaEventCount += 1
	end)

	propertyController:Destroy()

	local addOk: boolean, addReason: string? = tagController:AddTag("Buff.Sprint")

	expect(addOk).toBe(true)
	expect(addReason).toBeNil()
	expect(baseEventCount).toBe(0)
	expect(resolvedEventCount).toBe(0)
	expect(umbrellaEventCount).toBe(0)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	tagController:Destroy()
end)

it("treats repeated property-controller destroy calls as a no-op when tag connections were attached", function()
	local _actor: Actor, tagController: TagControllerType, propertyController: PropertyController =
		createControllerWithCatalog(MixedTagCatalog)

	propertyController:Destroy()
	propertyController:Destroy()

	tagController:Destroy()
end)
