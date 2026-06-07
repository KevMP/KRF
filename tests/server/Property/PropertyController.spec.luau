--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)
local PropertyTypes = require(ReplicatedStorage.Packages.KRF.server.Property.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController
type PropertyChange = PropertyTypes.PropertyChange

local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)
local PropertyControllerModule = require(ReplicatedStorage.Packages.KRF.server.Property.PropertyController)

it("initializes built-in properties with the documented defaults", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	expect(propertyController:HasProperty("WalkSpeed")).toBe(true)
	expect(propertyController:HasProperty("JumpPower")).toBe(true)
	expect(propertyController:GetBaseProperty("WalkSpeed")).toBe(16)
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(16)
	expect(propertyController:GetBaseProperty("JumpPower")).toBe(50)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(50)

	propertyController:Destroy()
end)

it("updates WalkSpeed without mutating the other built-in property", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local initialJumpPowerBase: number? = propertyController:GetBaseProperty("JumpPower")
	local initialJumpPowerResolved: number? = propertyController:GetResolvedProperty("JumpPower")

	expect(initialJumpPowerBase).never.toBeNil()
	expect(initialJumpPowerResolved).never.toBeNil()

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("WalkSpeed", 24)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(propertyController:GetBaseProperty("WalkSpeed")).toBe(24)
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(24)
	expect(propertyController:GetBaseProperty("JumpPower")).toBe(initialJumpPowerBase)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(initialJumpPowerResolved)

	propertyController:Destroy()
end)

it("creates a user-defined numeric property on first set and flips HasProperty to true", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	expect(propertyController:HasProperty("CriticalChance")).toBe(false)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("CriticalChance", 15)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(propertyController:HasProperty("CriticalChance")).toBe(true)
	expect(propertyController:GetBaseProperty("CriticalChance")).toBe(15)
	expect(propertyController:GetResolvedProperty("CriticalChance")).toBe(15)

	propertyController:Destroy()
end)

it("returns nil for missing properties and rejects non-numeric writes without creating them", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	expect(propertyController:HasProperty("Armor")).toBe(false)
	expect(propertyController:GetBaseProperty("Armor")).toBeNil()
	expect(propertyController:GetResolvedProperty("Armor")).toBeNil()

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("Armor", "heavy" :: any)

	expect(setOk).toBe(false)
	expect(setReason).toBe("InvalidPropertyValue")
	expect(propertyController:HasProperty("Armor")).toBe(false)
	expect(propertyController:GetBaseProperty("Armor")).toBeNil()
	expect(propertyController:GetResolvedProperty("Armor")).toBeNil()

	propertyController:Destroy()
end)

it("keeps resolved values mirrored with base values for new and updated properties in P1", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)

	local createOk: boolean, createReason: string? = propertyController:SetBaseProperty("Defense", 20)
	expect(createOk).toBe(true)
	expect(createReason).toBeNil()
	expect(propertyController:GetBaseProperty("Defense")).toBe(20)
	expect(propertyController:GetResolvedProperty("Defense")).toBe(20)

	local updateOk: boolean, updateReason: string? = propertyController:SetBaseProperty("Defense", 35)
	expect(updateOk).toBe(true)
	expect(updateReason).toBeNil()
	expect(propertyController:GetBaseProperty("Defense")).toBe(35)
	expect(propertyController:GetResolvedProperty("Defense")).toBe(35)

	propertyController:Destroy()
end)

it("does not fire change events when setting the same value already stored", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local initialWalkSpeed: number? = propertyController:GetBaseProperty("WalkSpeed")

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

	expect(initialWalkSpeed).never.toBeNil()

	local setOk: boolean, setReason: string? =
		propertyController:SetBaseProperty("WalkSpeed", initialWalkSpeed :: number)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(baseEventCount).toBe(0)
	expect(resolvedEventCount).toBe(0)
	expect(umbrellaEventCount).toBe(0)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	propertyController:Destroy()
end)

it("fires base, resolved, and umbrella events in order when creating a property", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local eventOrder: { string } = {}
	local umbrellaPayload: PropertyChange? = nil

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "base")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("Armor")
			expect(oldValue).toBeNil()
			expect(newValue).toBe(40)
		end
	)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			table.insert(eventOrder, "resolved")
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("Armor")
			expect(oldValue).toBeNil()
			expect(newValue).toBe(40)
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		table.insert(eventOrder, "umbrella")
		umbrellaPayload = change
	end)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("Armor", 40)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(eventOrder).toEqual({ "base", "resolved", "umbrella" })
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).actor).toBe(actor)
	expect((umbrellaPayload :: PropertyChange).propertyName).toBe("Armor")
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBeNil()
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(40)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBeNil()
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBe(40)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	propertyController:Destroy()
end)

it("fires specific change events only when values change and reports previous values on update", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local baseOldValue: number? = nil
	local baseNewValue: number? = nil
	local resolvedOldValue: number? = nil
	local resolvedNewValue: number? = nil
	local umbrellaPayload: PropertyChange? = nil

	local seedOk: boolean, seedReason: string? = propertyController:SetBaseProperty("WalkSpeed", 20)
	expect(seedOk).toBe(true)
	expect(seedReason).toBeNil()

	local baseEventCount: number = 0
	local resolvedEventCount: number = 0

	local baseConnection = propertyController.OnBasePropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			baseEventCount += 1
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("WalkSpeed")
			baseOldValue = oldValue
			baseNewValue = newValue
		end
	)
	local resolvedConnection = propertyController.OnResolvedPropertyChanged:Connect(
		function(eventActor: Actor, propertyName: string, oldValue: number?, newValue: number)
			resolvedEventCount += 1
			expect(eventActor).toBe(actor)
			expect(propertyName).toBe("WalkSpeed")
			resolvedOldValue = oldValue
			resolvedNewValue = newValue
		end
	)
	local umbrellaConnection = propertyController.OnPropertyChanged:Connect(function(change: PropertyChange)
		umbrellaPayload = change
	end)

	local setOk: boolean, setReason: string? = propertyController:SetBaseProperty("WalkSpeed", 30)

	expect(setOk).toBe(true)
	expect(setReason).toBeNil()
	expect(baseEventCount).toBe(1)
	expect(resolvedEventCount).toBe(1)
	expect(baseOldValue).toBe(20)
	expect(baseNewValue).toBe(30)
	expect(resolvedOldValue).toBe(20)
	expect(resolvedNewValue).toBe(30)
	expect(umbrellaPayload).never.toBeNil()
	expect((umbrellaPayload :: PropertyChange).oldBaseValue).toBe(20)
	expect((umbrellaPayload :: PropertyChange).newBaseValue).toBe(30)
	expect((umbrellaPayload :: PropertyChange).oldResolvedValue).toBe(20)
	expect((umbrellaPayload :: PropertyChange).newResolvedValue).toBe(30)

	baseConnection:Disconnect()
	resolvedConnection:Disconnect()
	umbrellaConnection:Disconnect()
	propertyController:Destroy()
end)

it("returns a frozen resolved-properties snapshot with built-in and user-defined properties together", function()
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local initialJumpPower: number? = propertyController:GetResolvedProperty("JumpPower")

	local setWalkSpeedOk: boolean, setWalkSpeedReason: string? = propertyController:SetBaseProperty("WalkSpeed", 28)
	local setCustomOk: boolean, setCustomReason: string? = propertyController:SetBaseProperty("Mana", 120)

	expect(setWalkSpeedOk).toBe(true)
	expect(setWalkSpeedReason).toBeNil()
	expect(setCustomOk).toBe(true)
	expect(setCustomReason).toBeNil()
	expect(initialJumpPower).never.toBeNil()

	local snapshot: { [string]: number } = propertyController:GetResolvedProperties()

	expect(snapshot.WalkSpeed).toBe(28)
	expect(snapshot.JumpPower).toBe(initialJumpPower)
	expect(snapshot.Mana).toBe(120)
	expect(table.isfrozen(snapshot)).toBe(true)

	local mutateOk: boolean, mutateError: any = pcall(function()
		snapshot.WalkSpeed = 999
	end)

	expect(mutateOk).toBe(false)
	expect(mutateError).never.toBeNil()
	expect(propertyController:GetResolvedProperty("WalkSpeed")).toBe(28)
	expect(propertyController:GetResolvedProperty("JumpPower")).toBe(initialJumpPower)
	expect(propertyController:GetResolvedProperty("Mana")).toBe(120)

	propertyController:Destroy()
end)
